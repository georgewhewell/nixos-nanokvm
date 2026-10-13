{
  buildLinux,
  fetchFromGitHub,
  fetchurl,
  kernelPatches,
  lib,
  ...
} @ args: let
  modDirVersion = "6.18.3";
in
  buildLinux (
    args
    // {
      inherit modDirVersion;
      version = "${modDirVersion}-spacemit-k3";

      src = fetchFromGitHub {
        owner = "liberodark";
        repo = "spacemit-linux-6.18";
        rev = "3709ed51967962fd02d6b4e5a80234719693931f";
        hash = "sha256-itqxXJCogLHbGucVHCDVwGkoqunQjJs0i1ZfvkuUtP4=";
      };

      # Upstream GCC 16 compatibility fix; the vendor 6.18.3 tree predates it.
      kernelPatches = kernelPatches ++ [{
        name = "gcc-plugins-gcc16";
        patch = fetchurl {
          url = "https://github.com/torvalds/linux/commit/905c559e51497b8bfdbb68df8be56d2f70f0de8e.patch";
          hash = "sha256-u8JlNOjG5DoH5/iKWxWQKTNrULIR2v00p6cPkqPdK/0=";
        };
      }];

      defconfig = "k3_bianbu_defconfig";

      postPatch = ''
        sed -i '/CONFIG_INITRAMFS_SOURCE=/d' arch/riscv/configs/k3_bianbu_defconfig
      '';

      structuredExtraConfig = let
        inherit (lib.kernel) yes no module;
      in {
        COMPILE_TEST = lib.mkForce no;
        SAMPLES = lib.mkForce no;
        KUNIT = lib.mkForce no;
        RUNTIME_TESTING_MENU = lib.mkForce no;
        RUNTIME_KERNEL_TESTING_MENU = lib.mkForce no;

        CGROUPS = yes;
        MEMCG = yes;
        CGROUP_BPF = yes;
        BPF = yes;
        BPF_SYSCALL = yes;
        BPF_JIT = yes;
        NAMESPACES = yes;
        USER_NS = yes;
        SECCOMP = yes;
        SECCOMP_FILTER = yes;
        DEVTMPFS = yes;
        DEVTMPFS_MOUNT = yes;
        AUTOFS_FS = yes;
        FANOTIFY = yes;
        TMPFS_POSIX_ACL = yes;
        TMPFS_XATTR = yes;
        MODULES = yes;
        MODULE_UNLOAD = yes;
        RD_GZIP = yes;
        RD_BZIP2 = yes;
        RD_LZMA = yes;
        RD_XZ = yes;
        RD_LZO = yes;
        RD_LZ4 = yes;
        RD_ZSTD = yes;
        MODULE_COMPRESS = lib.mkForce no;
        MODULE_COMPRESS_ALL = lib.mkForce no;
        MODULE_DECOMPRESS = lib.mkForce no;

        VIRTUALIZATION = lib.mkForce no;
        KVM = lib.mkForce no;
        PROFILING = lib.mkForce no;
        PM_DEBUG = lib.mkForce no;
        KPROBES = lib.mkForce no;
        UPROBES = lib.mkForce no;
        FTRACE = lib.mkForce no;
        TRACING = lib.mkForce no;
        DEBUG_KERNEL = lib.mkForce no;
        DEBUG_INFO = lib.mkForce no;
        DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT = lib.mkForce no;
        DEBUG_FS = lib.mkForce no;

        DRM = lib.mkForce no;
        FB = lib.mkForce no;
        MEDIA_SUPPORT = lib.mkForce no;
        SOUND = lib.mkForce no;
        SND = lib.mkForce no;
        BT = lib.mkForce no;
        WLAN = yes;
        WIRELESS = yes;
        CFG80211 = module;
        CFG80211_DEFAULT_PS = no;
        MAC80211 = module;
        WLAN_VENDOR_REALTEK = yes;
        RTW89 = module;
        RTW89_8852BE = module;
        COMEDI = lib.mkForce no;
        CAN = lib.mkForce no;
        NFC = lib.mkForce no;
        INFINIBAND = lib.mkForce no;
        RDMA = lib.mkForce no;
        GREYBUS = lib.mkForce no;
        FPGA = lib.mkForce no;
        JOYSTICK = lib.mkForce no;
        PATA = lib.mkForce no;

        PSTORE_BLK = no;
        PSTORE_BLK_BLKDEV = no;
        RTL8852BS = no;
        CORESIGHT = no;
        ETHERCAT = no;
        HWSPINLOCK_SPACEMIT = no;
        DRM_AMDGPU = no;
        DRM_RADEON = no;
        DRM_NOUVEAU = no;
        SPACEMIT_K1_CCU = no;
        NVMEM_LAYOUT_ONIE_TLV = no;
        DEBUG_VM = no;
        DEBUG_VM_PGFLAGS = no;
        DEBUG_VM_PGTABLE = no;
        DEBUG_PAGEALLOC = no;
        DEBUG_PAGEALLOC_ENABLE_DEFAULT = no;
        PAGE_EXTENSION = lib.mkForce no;
        PAGE_OWNER = no;
        KASAN = no;
        KMEMLEAK = no;
        DEBUG_KMEMLEAK = no;
        SLUB_DEBUG_ON = no;
        MEM_ALLOC_PROFILING = lib.mkForce no;
        MEM_ALLOC_PROFILING_ENABLED_BY_DEFAULT = lib.mkForce no;
        NO_HZ_FULL = lib.mkForce no;
        SLAB_FREELIST_HARDENED = lib.mkForce no;
        SLAB_FREELIST_RANDOM = lib.mkForce no;
        KFENCE = lib.mkForce no;
      };

      extraMeta = {
        branch = "k3-br-v1.0.y";
        description = "Vendor Linux kernel for SpacemiT K3 boards";
        homepage = "https://github.com/liberodark/spacemit-linux-6.18";
        maintainers = [lib.maintainers.georgewhewell];
        platforms = ["riscv64-linux"];
      };
    }
    // (args.argsOverride or {})
  )
