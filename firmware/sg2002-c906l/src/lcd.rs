//! PicoClaw ST7789 service. Ownership must be authorized before construction.
//!
//! No pinmux, clock, reset-controller, EPHY or Linux-owned register access is
//! performed here. Initialization and drawing advance in bounded task steps.
//! ST7789V section 8.6 permits CS-high pauses after complete bytes; each native
//! CS0 transaction therefore fits the SPI driver's eight-entry FIFO.

use core::ptr::NonNull;
use sg2002_pac::{gpio, spi};

const WIDTH: u16 = 240;
const HEIGHT: u16 = 240;
const Y_OFFSET: u16 = 80;
const DC: u32 = 1 << 28;
const RESET: u32 = 1 << 27;
const WIFI_POWER: u32 = 1 << 26;
// The backlight pad (A19) is muxed to PWM_7 and owned by Linux, so it is
// deliberately absent here: this bank never drives it.
const CONTROL_LINES: u32 = DC | RESET | WIFI_POWER;
const MAX_CHUNKS: usize = 32;
pub(crate) const FRAME_BYTES: usize = WIDTH as usize * HEIGHT as usize * 2;

#[derive(Clone, Copy, Debug)]
pub(crate) struct Config {
    pub spi_base: usize,
    pub gpio_base: usize,
    pub divider: u16,
    pub poll_budget: u32,
    pub framebuffer_base: usize,
    pub framebuffer_stride: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Job {
    Clear {
        color: u16,
    },
    FillRect {
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        color: u16,
    },
    Demo {
        seed: u32,
    },
    Frame {
        slot: u8,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum State {
    Initializing,
    Ready,
    Busy,
    Fault,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Error {
    Config,
    Busy,
    NotReady,
    InvalidSequence,
    Bounds,
    Gpio,
    Spi(spi::Error),
}

impl Error {
    /// Stable diagnostic code, independent of Rust enum layout.
    pub(crate) const fn code(self) -> u32 {
        match self {
            Self::Config => 1,
            Self::Busy => 2,
            Self::NotReady => 3,
            Self::InvalidSequence => 4,
            Self::Bounds => 5,
            Self::Gpio => 6,
            Self::Spi(spi::Error::Unconfigured) => 0x101,
            Self::Spi(spi::Error::TooLong) => 0x102,
            Self::Spi(spi::Error::Timeout) => 0x103,
            Self::Spi(spi::Error::FifoNotEmpty) => 0x104,
            Self::Spi(spi::Error::FifoFull) => 0x105,
            Self::Spi(spi::Error::Hardware(bits)) => 0x10000 | (bits & 0xffff),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct Status {
    pub state: State,
    pub accepted_sequence: u32,
    pub completed_sequence: u32,
    pub error: Option<Error>,
}

trait Io {
    fn dc(&mut self, high: bool) -> Result<(), Error>;
    fn reset(&mut self, high: bool) -> Result<(), Error>;
    fn write(&mut self, bytes: &[u8]) -> Result<(), Error>;
    /// Stream `count` pixels of a frame slot starting at `first`, as one
    /// transmit-only SPI burst with D/C already high.
    fn frame_stream(&mut self, slot: u8, first: u32, count: u32) -> Result<(), Error>;
}

/// Slots hold DRM_FORMAT_RGB565 (little-endian); the 16-bit SPI frame shifts
/// the word MSB first, which is the panel's byte order.
///
/// # Safety
/// `address` must be a mapped, 2-byte aligned pixel inside an owned slot.
unsafe fn slot_pixel(address: usize) -> u16 {
    // SAFETY: upheld by the caller.
    u16::from_le(unsafe { core::ptr::read_volatile(address as *const u16) })
}

struct Hardware {
    spi: spi::Spi<'static>,
    outputs: gpio::OutputGroup<'static>,
    poll_budget: u32,
    framebuffer_base: usize,
    framebuffer_stride: usize,
}
impl Hardware {
    fn line(&mut self, mask: u32, high: bool) -> Result<(), Error> {
        self.outputs
            .set(mask, if high { mask } else { 0 })
            .map_err(|_| Error::Gpio)
    }
}
impl Io for Hardware {
    fn dc(&mut self, high: bool) -> Result<(), Error> {
        self.line(DC, high)
    }
    fn reset(&mut self, high: bool) -> Result<(), Error> {
        self.line(RESET, high)
    }
    fn write(&mut self, bytes: &[u8]) -> Result<(), Error> {
        if bytes.len() > 8 {
            return Err(Error::Spi(spi::Error::TooLong));
        }
        let mut scratch = [0; 8];
        scratch[..bytes.len()].copy_from_slice(bytes);
        self.spi
            .transfer_in_place(&mut scratch[..bytes.len()], self.poll_budget)
            .map_err(Error::Spi)
    }
    fn frame_stream(&mut self, slot: u8, first: u32, count: u32) -> Result<(), Error> {
        let pixels = (FRAME_BYTES / 2) as u32;
        if slot > 1 || first > pixels || count > pixels - first {
            return Err(Error::Bounds);
        }
        let base = self.framebuffer_base + usize::from(slot) * self.framebuffer_stride;
        let words = (first..first + count).map(|pixel| {
            // SAFETY: Panel::new's caller guarantees both permanently mapped
            // slots and frame ownership/cache invalidation before submission;
            // the validated range stays inside one 115200-byte frame.
            unsafe { slot_pixel(base + pixel as usize * 2) }
        });
        self.spi
            .stream_words(words, self.poll_budget)
            .map_err(Error::Spi)
    }
}

struct InitCommand {
    command: u8,
    data: &'static [u8],
}
// Board-specific cold-start sequence from picoclaw-lcd-test.c. Keep these
// values together so the Rust and Linux diagnostic remain easy to compare.
const INIT: &[InitCommand] = &[
    InitCommand {
        command: 0xb2,
        data: &[0x1f, 0x1f, 0, 0x33, 0x33],
    },
    InitCommand {
        command: 0x36,
        data: &[0xc0],
    },
    InitCommand {
        command: 0x3a,
        data: &[0x05],
    },
    InitCommand {
        command: 0xb7,
        data: &[0],
    },
    InitCommand {
        command: 0xbb,
        data: &[0x36],
    },
    InitCommand {
        command: 0xc0,
        data: &[0x2c],
    },
    InitCommand {
        command: 0xc2,
        data: &[1],
    },
    InitCommand {
        command: 0xc3,
        data: &[0x13],
    },
    InitCommand {
        command: 0xc4,
        data: &[0x20],
    },
    InitCommand {
        command: 0xc6,
        data: &[0x13],
    },
    InitCommand {
        command: 0xd6,
        data: &[0xa1],
    },
    InitCommand {
        command: 0xd0,
        data: &[0xa4, 0xa1],
    },
    InitCommand {
        command: 0xe0,
        data: &[
            0xf0, 0x08, 0x0e, 0x09, 0x08, 0x04, 0x2f, 0x33, 0x45, 0x36, 0x13, 0x12, 0x2a, 0x2d,
        ],
    },
    InitCommand {
        command: 0xe1,
        data: &[
            0xf0, 0x0e, 0x12, 0x0c, 0x0a, 0x15, 0x2e, 0x32, 0x44, 0x39, 0x17, 0x18, 0x2b, 0x2f,
        ],
    },
    InitCommand {
        command: 0xe4,
        data: &[0x1d, 0, 0],
    },
    InitCommand {
        command: 0x21,
        data: &[],
    },
    InitCommand {
        command: 0x11,
        data: &[],
    },
    InitCommand {
        command: 0x29,
        data: &[],
    },
];

#[derive(Clone, Copy)]
enum AfterDelay {
    ResetLow,
    ResetHigh,
    SleepOut,
    Init,
    Ready,
}
#[derive(Clone, Copy)]
enum Phase {
    Delay {
        deadline: Option<u32>,
        ticks: u32,
        next: AfterDelay,
    },
    Init {
        index: usize,
        offset: usize,
    },
    Ready,
    Draw(Render),
    Fault,
}
#[derive(Clone, Copy)]
struct Render {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    source: Pixels,
    stage: u8,
    pixel: u32,
}
#[derive(Clone, Copy)]
enum Pixels {
    Solid(u16),
    Demo(u32),
    Frame(u8),
}
impl Render {
    fn new(job: Job) -> Result<Self, Error> {
        let (x, y, width, height, source) = match job {
            Job::Clear { color } => (0, 0, WIDTH, HEIGHT, Pixels::Solid(color)),
            Job::FillRect {
                x,
                y,
                width,
                height,
                color,
            } => (x, y, width, height, Pixels::Solid(color)),
            Job::Demo { seed } => (0, 0, WIDTH, HEIGHT, Pixels::Demo(seed)),
            Job::Frame {
                slot,
                x,
                y,
                width,
                height,
            } if slot < 2 => (x, y, width, height, Pixels::Frame(slot)),
            Job::Frame { .. } => return Err(Error::Bounds),
        };
        if width == 0
            || height == 0
            || u32::from(x) + u32::from(width) > u32::from(WIDTH)
            || u32::from(y) + u32::from(height) > u32::from(HEIGHT)
        {
            return Err(Error::Bounds);
        }
        Ok(Self {
            x,
            y,
            width,
            height,
            source,
            stage: 0,
            pixel: 0,
        })
    }
}

struct Engine<I> {
    io: I,
    phase: Phase,
    status: Status,
    last_job: Option<Job>,
}
impl<I: Io> Engine<I> {
    fn new(io: I) -> Self {
        Self {
            io,
            phase: Self::delay(10, AfterDelay::ResetLow), // 50 ms at 200 Hz.
            status: Status {
                state: State::Initializing,
                accepted_sequence: 0,
                completed_sequence: 0,
                error: None,
            },
            last_job: None,
        }
    }
    fn delay(ticks: u32, next: AfterDelay) -> Phase {
        // Arm on the next task step, after the preceding GPIO/SPI action has
        // completed, so a stale `now` cannot shorten a required panel delay.
        Phase::Delay {
            deadline: None,
            ticks,
            next,
        }
    }
    fn submit(&mut self, sequence: u32, job: Job) -> Result<(), Error> {
        if self.status.state == State::Fault {
            return Err(self.status.error.unwrap_or(Error::NotReady));
        }
        if sequence == 0 {
            return Err(Error::InvalidSequence);
        }
        if sequence == self.status.accepted_sequence {
            return if self.last_job == Some(job) {
                Ok(())
            } else {
                Err(Error::InvalidSequence)
            };
        }
        if self.status.state == State::Initializing {
            return Err(Error::NotReady);
        }
        if self.status.state == State::Busy {
            return Err(Error::Busy);
        }
        let phase = Phase::Draw(Render::new(job)?);
        self.last_job = Some(job);
        self.phase = phase;
        self.status.state = State::Busy;
        self.status.accepted_sequence = sequence;
        Ok(())
    }
    fn write(&mut self, data: bool, bytes: &[u8]) -> Result<(), Error> {
        // Previous SPI call already completed and deasserted native CS0.
        self.io.dc(data)?;
        self.io.write(bytes)
    }
    fn complete(&mut self) {
        self.phase = Phase::Ready;
        self.status.state = State::Ready;
        self.status.completed_sequence = self.status.accepted_sequence;
    }
    fn step(&mut self, now: u32) {
        if let Err(error) = self.advance(now) {
            // SPI already halted on transfer failure. Keep bank ownership and
            // leave the panel as it is; the Linux driver blanks the backlight
            // when it observes the fault. Do not replay a partially drawn job.
            self.phase = Phase::Fault;
            self.status.state = State::Fault;
            self.status.error = Some(error);
        }
    }
    fn advance(&mut self, now: u32) -> Result<(), Error> {
        for _ in 0..MAX_CHUNKS {
            match self.phase {
                Phase::Ready | Phase::Fault => return Ok(()),
                Phase::Delay {
                    deadline: None,
                    ticks,
                    next,
                } => {
                    self.phase = Phase::Delay {
                        deadline: Some(now.wrapping_add(ticks)),
                        ticks,
                        next,
                    };
                    return Ok(());
                }
                Phase::Delay {
                    deadline: Some(deadline),
                    next,
                    ..
                } => {
                    if (now.wrapping_sub(deadline) as i32) < 0 {
                        return Ok(());
                    }
                    self.phase = match next {
                        AfterDelay::ResetLow => {
                            self.io.reset(false)?;
                            Self::delay(10, AfterDelay::ResetHigh)
                        }
                        AfterDelay::ResetHigh => {
                            self.io.reset(true)?;
                            Self::delay(24, AfterDelay::SleepOut)
                        }
                        AfterDelay::SleepOut => {
                            self.write(false, &[0x11])?;
                            Self::delay(24, AfterDelay::Init)
                        }
                        AfterDelay::Init => Phase::Init {
                            index: 0,
                            offset: 0,
                        },
                        AfterDelay::Ready => {
                            self.status.state = State::Ready;
                            Phase::Ready
                        }
                    };
                    // Next delay is armed in a later step, after these actions.
                    return Ok(());
                }
                Phase::Init { index, offset } => {
                    if index == INIT.len() {
                        self.phase = Self::delay(20, AfterDelay::Ready);
                        return Ok(());
                    }
                    let command = &INIT[index];
                    if offset == 0 {
                        self.write(false, &[command.command])?;
                        self.phase = if command.data.is_empty() {
                            Phase::Init {
                                index: index + 1,
                                offset: 0,
                            }
                        } else {
                            Phase::Init { index, offset: 1 }
                        };
                    } else {
                        let begin = offset - 1;
                        let end = (begin + 8).min(command.data.len());
                        self.write(true, &command.data[begin..end])?;
                        self.phase = if end == command.data.len() {
                            Phase::Init {
                                index: index + 1,
                                offset: 0,
                            }
                        } else {
                            Phase::Init {
                                index,
                                offset: end + 1,
                            }
                        };
                    }
                }
                Phase::Draw(mut render) => {
                    match render.stage {
                        0 => self.write(false, &[0x2a])?,
                        1 => {
                            let start = render.x.to_be_bytes();
                            let end = (render.x + render.width - 1).to_be_bytes();
                            self.write(true, &[start[0], start[1], end[0], end[1]])?;
                        }
                        2 => self.write(false, &[0x2b])?,
                        3 => {
                            let start = (render.y + Y_OFFSET).to_be_bytes();
                            let end = (render.y + Y_OFFSET + render.height - 1).to_be_bytes();
                            self.write(true, &[start[0], start[1], end[0], end[1]])?;
                        }
                        4 => self.write(false, &[0x2c])?,
                        _ => {
                            let remaining =
                                u32::from(render.width) * u32::from(render.height) - render.pixel;
                            if let Pixels::Frame(slot) = render.source {
                                // One burst per frame (~79 ms at 11.719 MHz) must
                                // stay well inside the heartbeat period.
                                self.io.dc(true)?;
                                self.io.frame_stream(slot, render.pixel, remaining)?;
                                self.complete();
                                return Ok(());
                            }
                            let pixels = remaining.min(4);
                            let mut bytes = [0; 8];
                            for index in 0..pixels {
                                let position = render.pixel + index;
                                let color = match render.source {
                                    Pixels::Demo(seed) => demo_pixel(
                                        (position % u32::from(WIDTH)) as u16,
                                        (position / u32::from(WIDTH)) as u16,
                                        seed,
                                    ),
                                    Pixels::Solid(color) => color,
                                    Pixels::Frame(_) => unreachable!(),
                                }
                                .to_be_bytes();
                                bytes[index as usize * 2..index as usize * 2 + 2]
                                    .copy_from_slice(&color);
                            }
                            self.write(true, &bytes[..pixels as usize * 2])?;
                            render.pixel += pixels;
                            if pixels == remaining {
                                self.complete();
                                return Ok(());
                            }
                        }
                    }
                    render.stage = render.stage.saturating_add(1).min(5);
                    self.phase = Phase::Draw(render);
                }
            }
        }
        Ok(())
    }
}

fn demo_pixel(x: u16, y: u16, seed: u32) -> u16 {
    let mut color = match x / 80 {
        0 => 0xf800,
        1 => 0x07e0,
        _ => 0x001f,
    };
    if y >= 192 {
        color = if ((u32::from(x / 12) + u32::from(y / 12)) ^ seed) & 1 == 0 {
            0xffff
        } else {
            0
        };
    }
    if (20..220).contains(&x) && (64..160).contains(&y) {
        color = if x == 20 || x == 219 || y == 64 || y == 159 {
            0xffff
        } else {
            0
        };
    }
    // Five 5x7 glyphs, scaled four times: "C906L".
    const GLYPHS: [[u8; 7]; 5] = [
        [14, 17, 16, 16, 16, 17, 14],
        [14, 17, 17, 15, 1, 1, 14],
        [14, 17, 19, 21, 25, 17, 14],
        [6, 8, 16, 30, 17, 17, 14],
        [16, 16, 16, 16, 16, 16, 31],
    ];
    if (60..180).contains(&x) && (96..124).contains(&y) {
        let cell = usize::from((x - 60) / 24);
        let column = (x - 60) % 24 / 4;
        if column < 5 && GLYPHS[cell][usize::from((y - 96) / 4)] & (1 << (4 - column)) != 0 {
            color = 0xffff;
        }
    }
    color
}

pub(crate) struct Panel {
    engine: Engine<Hardware>,
}
impl Panel {
    /// # Safety
    /// Must be called once, after Linux authorizes the exact whole SPI1/GPIO0
    /// lease and pins. No CPU, IRQ, DMA, U-Boot or Linux owner may access those
    /// banks concurrently. Mappings remain valid for the firmware lifetime.
    /// SPI clock/divisor, resets, pinmux, voltage and PicoClaw EPHY pad handoff
    /// must already be established and remain stable. No such setup occurs here.
    /// Both framebuffer slots must be permanently mapped; before submitting
    /// Frame, the caller acquires that slot, invalidates its entire 115200-byte
    /// cache range and keeps Linux from modifying it until completion/fault.
    pub(crate) unsafe fn new(config: Config, _now_ticks: u32) -> Result<Self, Error> {
        // This board driver cannot be retargeted to a console or camera bank.
        if config.spi_base != 0x0419_0000
            || config.gpio_base != 0x0302_0000
            || config.poll_budget == 0
            || config.poll_budget > 100_000
            || config.framebuffer_base != 0x8ff5_1000
            || config.framebuffer_stride != 0x1d000
        {
            return Err(Error::Config);
        }
        let divider = spi::Divider::new(config.divider).ok_or(Error::Config)?;
        let spi_base = NonNull::new(config.spi_base as *mut u8).ok_or(Error::Config)?;
        let gpio_base = NonNull::new(config.gpio_base as *mut u8).ok_or(Error::Config)?;
        // SAFETY: the caller provides exclusive, activated, permanent mappings;
        // exact PicoClaw addresses and scalar configuration were checked above.
        let mut bank = unsafe { gpio::Bank::from_base(gpio_base) };
        bank.mask_interrupts();
        // Wi-Fi off first; reset high and DC low before SPI.  One OutputGroup
        // owns all three lines, so Wi-Fi and LCD operations cannot race a
        // whole-bank read/modify/write.
        let outputs = bank.outputs(CONTROL_LINES, RESET);
        let mut spi = unsafe { spi::Spi::from_base(spi_base) };
        spi.configure(divider, embedded_hal::spi::MODE_0);
        Ok(Self {
            engine: Engine::new(Hardware {
                spi,
                outputs,
                poll_budget: config.poll_budget,
                framebuffer_base: config.framebuffer_base,
                framebuffer_stride: config.framebuffer_stride,
            }),
        })
    }
    /// MMIO-free request validation/admission. Duplicate last sequence/job is
    /// idempotent, including while busy; a different job with it is rejected.
    pub(crate) fn submit(&mut self, sequence: u32, job: Job) -> Result<(), Error> {
        self.engine.submit(sequence, job)
    }
    /// At most 32 SPI transactions, each <=8 bytes. Caller must yield between
    /// steps (normally one 200 Hz scheduler tick) and keep control tasks live.
    pub(crate) fn step(&mut self, now_ticks: u32) {
        self.engine.step(now_ticks);
    }
    pub(crate) fn status(&self) -> Status {
        self.engine.status
    }

    /// Called only by the same task that advances LCD scanout. The Linux
    /// regulator supplies power-cycle delays; acknowledgement follows latch
    /// readback, not just queuing a future GPIO update.
    pub(crate) fn wifi_power(&mut self, enabled: bool) -> Result<(), Error> {
        self.engine.io.line(WIFI_POWER, enabled)?;
        let actual = self
            .engine
            .io
            .outputs
            .get(WIFI_POWER)
            .map_err(|_| Error::Gpio)?;
        if actual != if enabled { WIFI_POWER } else { 0 } {
            return Err(Error::Gpio);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;
    use std::{vec, vec::Vec};

    #[derive(Debug, PartialEq)]
    enum Event {
        Dc(bool),
        Reset(bool, u32),
        Write(bool, Vec<u8>, u32),
        Frame(u8, usize, usize),
    }
    #[derive(Default)]
    struct Fake {
        dc: bool,
        now: u32,
        writes: usize,
        fail_after: Option<usize>,
        events: Vec<Event>,
    }
    impl Io for Fake {
        fn dc(&mut self, high: bool) -> Result<(), Error> {
            self.dc = high;
            self.events.push(Event::Dc(high));
            Ok(())
        }
        fn reset(&mut self, high: bool) -> Result<(), Error> {
            self.events.push(Event::Reset(high, self.now));
            Ok(())
        }
        fn write(&mut self, bytes: &[u8]) -> Result<(), Error> {
            assert!(!bytes.is_empty() && bytes.len() <= 8);
            assert_eq!(self.events.last(), Some(&Event::Dc(self.dc)));
            if self.fail_after == Some(self.writes) {
                return Err(Error::Spi(spi::Error::Timeout));
            }
            self.writes += 1;
            self.events
                .push(Event::Write(self.dc, bytes.to_vec(), self.now));
            Ok(())
        }
        fn frame_stream(&mut self, slot: u8, first: u32, count: u32) -> Result<(), Error> {
            assert!(slot < 2 && (first + count) as usize * 2 <= FRAME_BYTES);
            assert_eq!(self.events.last(), Some(&Event::Dc(true)));
            if self.fail_after == Some(self.writes) {
                return Err(Error::Spi(spi::Error::Timeout));
            }
            self.writes += 1;
            self.events
                .push(Event::Frame(slot, first as usize, count as usize));
            Ok(())
        }
    }
    fn step(engine: &mut Engine<Fake>, now: u32) {
        engine.io.now = now;
        let before = engine.io.writes;
        engine.step(now);
        assert!(engine.io.writes - before <= MAX_CHUNKS);
    }
    fn initialized(start: u32) -> (Engine<Fake>, u32) {
        let mut engine = Engine::new(Fake::default());
        for offset in 0..1000 {
            let now = start.wrapping_add(offset);
            step(&mut engine, now);
            if engine.status.state == State::Ready {
                return (engine, now);
            }
        }
        panic!("initialization did not complete");
    }
    fn writes(engine: &Engine<Fake>) -> Vec<(bool, Vec<u8>)> {
        engine
            .io
            .events
            .iter()
            .filter_map(|event| match event {
                Event::Write(data, bytes, _) => Some((*data, bytes.clone())),
                _ => None,
            })
            .collect()
    }
    #[test]
    fn initialization_preserves_full_tables() {
        let (engine, _) = initialized(0);
        let transfers = writes(&engine);
        let mut expected = vec![(false, vec![0x11])];
        for item in INIT {
            expected.push((false, vec![item.command]));
            for chunk in item.data.chunks(8) {
                expected.push((true, chunk.to_vec()));
            }
        }
        assert_eq!(transfers, expected);
        assert_eq!(engine.status.accepted_sequence, 0);
        assert_eq!(engine.status.completed_sequence, 0);
    }
    #[test]
    fn hardware_waits_are_nonblocking_and_survive_tick_wrap() {
        let start = u32::MAX - 20;
        let (engine, ready) = initialized(start);
        let mut reset = Vec::new();
        let mut commands = Vec::new();
        for event in &engine.io.events {
            match event {
                Event::Reset(high, tick) => reset.push((*high, *tick)),
                Event::Write(false, bytes, tick) => commands.push((bytes[0], *tick)),
                _ => (),
            }
        }
        assert_eq!(reset.len(), 2);
        assert_eq!(reset[0].0, false);
        assert_eq!(reset[1].0, true);
        assert!(reset[0].1.wrapping_sub(start) >= 10);
        assert!(reset[1].1.wrapping_sub(reset[0].1) >= 10);
        assert!(commands[0].1.wrapping_sub(reset[1].1) >= 24);
        assert!(commands[1].1.wrapping_sub(commands[0].1) >= 24);
        assert!(ready.wrapping_sub(commands.last().unwrap().1) >= 20);
    }
    #[test]
    fn rectangle_bounds_and_sequence_admission_do_not_touch_hardware() {
        let mut cold = Engine::new(Fake::default());
        assert_eq!(
            cold.submit(1, Job::Clear { color: 0 }),
            Err(Error::NotReady)
        );
        assert!(cold.io.events.is_empty());
        let (mut engine, _) = initialized(0);
        let count = engine.io.events.len();
        for (x, y, width, height) in [
            (0, 0, 0, 1),
            (239, 0, 2, 1),
            (0, 239, 1, 2),
            (u16::MAX, 0, 1, 1),
            (0, 0, 1, u16::MAX),
        ] {
            assert_eq!(
                engine.submit(
                    1,
                    Job::FillRect {
                        x,
                        y,
                        width,
                        height,
                        color: 0
                    }
                ),
                Err(Error::Bounds)
            );
        }
        assert_eq!(
            engine.submit(
                1,
                Job::Frame {
                    slot: 2,
                    x: 0,
                    y: 0,
                    width: WIDTH,
                    height: HEIGHT,
                },
            ),
            Err(Error::Bounds)
        );
        assert_eq!(
            engine.submit(0, Job::Clear { color: 0 }),
            Err(Error::InvalidSequence)
        );
        let job = Job::Clear { color: 0x1234 };
        engine.submit(1, job).unwrap();
        engine.submit(1, job).unwrap();
        assert_eq!(
            engine.submit(1, Job::Clear { color: 7 }),
            Err(Error::InvalidSequence)
        );
        assert_eq!(engine.submit(2, job), Err(Error::Busy));
        assert_eq!(engine.io.events.len(), count);
        assert_eq!(engine.status.accepted_sequence, 1);
        assert_eq!(engine.status.completed_sequence, 0);
    }
    #[test]
    fn last_pixel_window_and_rgb565_order_are_exact() {
        let (mut engine, now) = initialized(0);
        engine.io.events.clear();
        engine
            .submit(
                7,
                Job::FillRect {
                    x: 239,
                    y: 239,
                    width: 1,
                    height: 1,
                    color: 0x1234,
                },
            )
            .unwrap();
        step(&mut engine, now + 1);
        assert_eq!(
            writes(&engine),
            vec![
                (false, vec![0x2a]),
                (true, vec![0, 239, 0, 239]),
                (false, vec![0x2b]),
                (true, vec![1, 63, 1, 63]),
                (false, vec![0x2c]),
                (true, vec![0x12, 0x34]),
            ]
        );
        assert_eq!(engine.status.completed_sequence, 7);
        assert_eq!(engine.status.state, State::Ready);
        let events = engine.io.events.len();
        engine
            .submit(
                7,
                Job::FillRect {
                    x: 239,
                    y: 239,
                    width: 1,
                    height: 1,
                    color: 0x1234,
                },
            )
            .unwrap();
        step(&mut engine, now + 2);
        assert_eq!(engine.io.events.len(), events);
    }
    #[test]
    fn partial_final_chunk_contains_only_complete_pixels() {
        let (mut engine, now) = initialized(0);
        engine.io.events.clear();
        engine
            .submit(
                1,
                Job::FillRect {
                    x: 0,
                    y: 0,
                    width: 5,
                    height: 1,
                    color: 0xabcd,
                },
            )
            .unwrap();
        step(&mut engine, now + 1);
        let data = writes(&engine);
        assert_eq!(
            data[5],
            (true, vec![0xab, 0xcd, 0xab, 0xcd, 0xab, 0xcd, 0xab, 0xcd])
        );
        assert_eq!(data[6], (true, vec![0xab, 0xcd]));
    }
    #[test]
    fn slot_pixels_are_little_endian_rgb565() {
        let slot: [u16; 2] = [
            u16::from_le_bytes([0x34, 0x12]),
            u16::from_le_bytes([0x00, 0xf8]),
        ];
        let base = slot.as_ptr() as usize;
        // SAFETY: both addresses are aligned elements of `slot`.
        let pixels = unsafe { [slot_pixel(base), slot_pixel(base + 2)] };
        assert_eq!(pixels, [0x1234, 0xf800]);
    }
    #[test]
    fn frame_streams_selected_slot_in_one_step() {
        let (mut engine, now) = initialized(0);
        engine.io.events.clear();
        engine
            .submit(
                19,
                Job::Frame {
                    slot: 1,
                    x: 0,
                    y: 0,
                    width: WIDTH,
                    height: HEIGHT,
                },
            )
            .unwrap();
        step(&mut engine, now + 1);
        assert_eq!(engine.status.state, State::Ready);
        assert_eq!(engine.status.completed_sequence, 19);
        let frames: Vec<_> = engine
            .io
            .events
            .iter()
            .filter(|event| matches!(event, Event::Frame(..)))
            .collect();
        assert_eq!(frames, vec![&Event::Frame(1, 0, FRAME_BYTES / 2)]);
        // Window setup and RAMWR go through byte transactions; no pixel bytes do.
        assert_eq!(writes(&engine).len(), 5);
    }
    #[test]
    fn frame_stream_failure_is_sticky() {
        let (mut engine, now) = initialized(0);
        engine
            .submit(
                3,
                Job::Frame {
                    slot: 0,
                    x: 0,
                    y: 0,
                    width: WIDTH,
                    height: HEIGHT,
                },
            )
            .unwrap();
        engine.io.fail_after = Some(engine.io.writes + 5);
        step(&mut engine, now + 1);
        assert_eq!(engine.status.state, State::Fault);
        assert_eq!(engine.status.completed_sequence, 0);
        let count = engine.io.events.len();
        step(&mut engine, now + 2);
        assert_eq!(engine.io.events.len(), count);
    }
    #[test]
    fn spi_failure_is_sticky_without_completing_job() {
        let (mut engine, now) = initialized(0);
        engine.submit(4, Job::Demo { seed: 0 }).unwrap();
        engine.io.fail_after = Some(engine.io.writes + 6);
        step(&mut engine, now + 1);
        assert_eq!(engine.status.state, State::Fault);
        assert_eq!(engine.status.accepted_sequence, 4);
        assert_eq!(engine.status.completed_sequence, 0);
        assert_eq!(engine.status.error.unwrap().code(), 0x103);
        let count = engine.io.events.len();
        step(&mut engine, now + 2);
        assert!(engine.submit(5, Job::Clear { color: 0 }).is_err());
        assert_eq!(engine.io.events.len(), count);
    }
    #[test]
    fn demo_has_rgb_bars_and_seed_changes_checker() {
        assert_eq!(demo_pixel(0, 0, 0), 0xf800);
        assert_eq!(demo_pixel(80, 0, 0), 0x07e0);
        assert_eq!(demo_pixel(160, 0, 0), 0x001f);
        assert_ne!(demo_pixel(0, 200, 0), demo_pixel(0, 200, 1));
    }

    #[test]
    fn bad_configuration_is_rejected_before_any_physical_access() {
        let config = Config {
            spi_base: 0x0419_0000,
            gpio_base: 0x0302_0000,
            divider: 2,
            poll_budget: 1000,
            framebuffer_base: 0x8ff5_1000,
            framebuffer_stride: 0x1d000,
        };
        for invalid in [
            Config {
                spi_base: 0,
                ..config
            },
            Config {
                gpio_base: 0,
                ..config
            },
            Config {
                divider: 3,
                ..config
            },
            Config {
                poll_budget: 0,
                ..config
            },
            Config {
                poll_budget: 100_001,
                ..config
            },
            Config {
                framebuffer_base: 0,
                ..config
            },
            Config {
                framebuffer_stride: 1,
                ..config
            },
        ] {
            // SAFETY: each deliberately invalid scalar must be rejected before
            // an MMIO handle is constructed or accessed; no mapping is needed.
            assert!(matches!(
                unsafe { Panel::new(invalid, 0) },
                Err(Error::Config)
            ));
        }
    }
    #[test]
    fn failed_initialization_never_becomes_ready_or_accepts_drawing() {
        let mut engine = Engine::new(Fake {
            fail_after: Some(0),
            ..Fake::default()
        });
        for now in 0..200 {
            step(&mut engine, now);
        }
        assert_eq!(engine.status.state, State::Fault);
        assert_eq!(engine.status.accepted_sequence, 0);
        assert_eq!(engine.status.completed_sequence, 0);
        assert_eq!(engine.status.error, Some(Error::Spi(spi::Error::Timeout)));
        assert_eq!(
            engine.submit(1, Job::Demo { seed: 0 }),
            Err(Error::Spi(spi::Error::Timeout))
        );
    }
}
