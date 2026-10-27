# Make Android 12/13 init read mmap_rnd_compat_bits from /dev/.nk-vm/ instead
# of /proc/sys/vm/ (absent on kernels without CONFIG_COMPAT; init aborts).
# Same-length in-place string patch; writes <in>.patched.
import sys
src = open(sys.argv[1], "rb").read()
old = b"/proc/sys/vm/mmap_rnd_compat_bits\0"
new = b"/dev/.nk-vm//mmap_rnd_compat_bits\0"
assert len(old) == len(new) and src.count(old) == 1, "unexpected init binary"
open(sys.argv[1].replace(".orig", "") + ".patched", "wb").write(src.replace(old, new))
