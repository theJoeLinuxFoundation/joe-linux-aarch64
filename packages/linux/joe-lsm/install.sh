#!/bin/bash
# Adds the joe security module to an unpacked kernel tree (the current
# directory). Run from the kernel recipe's prepare step.
#
#   install.sh DIRECTORY_WITH_THIS_FILE
set -euo pipefail
src=$1

[[ -e $src/joe_keys.h ]] || {
    echo "joe-lsm: joe_keys.h is missing; it is generated from the code-signing key by bootstrap/build-packages.sh" >&2
    exit 1
}
mkdir security/joe
cp "$src/joe.c" "$src/joe_keys.h" "$src/Kconfig" "$src/Makefile" security/joe/

# Each edit must find its anchor: a kernel update that moves one should fail
# here rather than produce a kernel without the module.
edit() { # edit FILE ANCHOR_REGEX SED_COMMAND [RESULT_REGEX]
    grep -q "$2" "$1" || { echo "joe-lsm: anchor not found in $1: $2" >&2; exit 1; }
    sed -i "$3" "$1"
    if [[ $# -eq 4 ]] && ! grep -q "$4" "$1"; then
        echo "joe-lsm: edit did not apply in $1: $4" >&2
        exit 1
    fi
}
edit security/Kconfig '^source "security/ipe/Kconfig"' \
    's|^source "security/ipe/Kconfig"|&\nsource "security/joe/Kconfig"|'
edit security/Makefile '^obj-$(CONFIG_SECURITY_IPE)' \
    's|^obj-$(CONFIG_SECURITY_IPE).*|&\nobj-$(CONFIG_SECURITY_JOE)\t\t+= joe/|'
edit include/uapi/linux/lsm.h '^#define LSM_ID_IPE' \
    's|^#define LSM_ID_IPE.*|&\n#define LSM_ID_JOE\t\t114|'
edit include/linux/lsm_count.h '^#if IS_ENABLED(CONFIG_SECURITY_IPE)' \
    's|^#if IS_ENABLED(CONFIG_SECURITY_IPE)|#if IS_ENABLED(CONFIG_SECURITY_JOE)\n#define JOE_ENABLED 1,\n#else\n#define JOE_ENABLED\n#endif\n\n&|'
edit include/linux/lsm_count.h 'IPE_ENABLED)' \
    's|\t\tIPE_ENABLED)|\t\tIPE_ENABLED\t\t\\\n\t\tJOE_ENABLED)|'
grep -q 'JOE_ENABLED)' include/linux/lsm_count.h || { echo "joe-lsm: could not register in lsm_count.h" >&2; exit 1; }

# Mediate writes to another process's memory.  The two call sites supply
# different context: access_remote_vm has the VMA, process_vm has the task.
edit include/linux/lsm_hook_defs.h '^LSM_HOOK(int, 0, file_mprotect, struct vm_area_struct \*vma,$' \
    '/^LSM_HOOK(int, 0, file_mprotect, struct vm_area_struct \*vma,$/,/^LSM_HOOK(int, 0, file_lock,/ {
        s|^[[:space:]]*unsigned long reqprot, unsigned long prot)$|&\nLSM_HOOK(int, 0, remote_write, struct task_struct *task, struct vm_area_struct *vma)|
    }' \
    '^LSM_HOOK(int, 0, remote_write, struct task_struct \*task, struct vm_area_struct \*vma)$'

edit include/linux/security.h '^int security_file_mprotect(struct vm_area_struct \*vma, unsigned long reqprot,$' \
    '/^int security_file_mprotect(struct vm_area_struct \*vma, unsigned long reqprot,$/,/^int security_file_lock(struct file \*file, unsigned int cmd);$/ {
        s|^int security_file_lock(struct file \*file, unsigned int cmd);$|int security_remote_write(struct task_struct *task, struct vm_area_struct *vma);\n&|
    }' \
    '^int security_remote_write(struct task_struct \*task, struct vm_area_struct \*vma);$'
edit include/linux/security.h '^static inline int security_file_mprotect(struct vm_area_struct \*vma,$' \
    '/^static inline int security_file_mprotect(struct vm_area_struct \*vma,$/,/^static inline int security_file_lock(struct file \*file, unsigned int cmd)$/ {
        s|^static inline int security_file_lock(struct file \*file, unsigned int cmd)$|static inline int security_remote_write(struct task_struct *task,\n\t\t\t\t       struct vm_area_struct *vma)\n{\n\treturn 0;\n}\n\n&|
    }' \
    '^static inline int security_remote_write(struct task_struct \*task,$'

edit security/security.c '^int security_file_mprotect(struct vm_area_struct \*vma, unsigned long reqprot,$' \
    '/^int security_file_mprotect(struct vm_area_struct \*vma, unsigned long reqprot,$/,/^ \* security_file_lock() - Check if a file lock is allowed$/ {
        s|^}$|}\n\n/**\n * security_remote_write() - Check if a remote memory write is allowed\n * @task: target task, or NULL\n * @vma: target VMA, or NULL\n *\n * @task is known for process_vm and @vma for access_remote_vm; either can be\n * NULL.\n *\n * Return: Returns 0 if permission is granted.\n */\nint security_remote_write(struct task_struct *task, struct vm_area_struct *vma)\n{\n\treturn call_int_hook(remote_write, task, vma);\n}|
    }' \
    '^int security_remote_write(struct task_struct \*task, struct vm_area_struct \*vma)$'

edit mm/memory.c '^#include <linux/ptrace.h>$' \
    's|^#include <linux/ptrace.h>$|&\n#include <linux/security.h>|'
edit mm/memory.c '^static int __access_remote_vm(struct mm_struct \*mm, unsigned long addr,$' \
    '/^static int __access_remote_vm(struct mm_struct \*mm, unsigned long addr,$/,/^int access_remote_vm(struct mm_struct \*mm, unsigned long addr,$/ {
        /^[[:space:]]*struct page \*page = get_user_page_vma_remote(mm, addr,$/,/^[[:space:]]*if (IS_ERR(page)) {$/ {
            s|^\([[:space:]]*\)if (IS_ERR(page)) {$|\1if (write \&\& security_remote_write(NULL, vma)) {\n\1\tif (!IS_ERR(page))\n\1\t\tput_page(page);\n\1\tbreak;\n\1}\n\n&|
        }
    }' \
    '^[[:space:]]*if (write && security_remote_write(NULL, vma)) {$'

edit mm/process_vm_access.c '^#include <linux/ptrace.h>$' \
    's|^#include <linux/ptrace.h>$|&\n#include <linux/security.h>|'
edit mm/process_vm_access.c '^static ssize_t process_vm_rw_core(pid_t pid, struct iov_iter \*iter,$' \
    '/^static ssize_t process_vm_rw_core(pid_t pid, struct iov_iter \*iter,$/,/^static ssize_t process_vm_rw(pid_t pid,$/ {
        /^[[:space:]]*task = find_get_task_by_vpid(pid);$/,/^[[:space:]]*mm = mm_access(task, PTRACE_MODE_ATTACH_REALCREDS);$/ {
            s|^\([[:space:]]*\)mm = mm_access(task, PTRACE_MODE_ATTACH_REALCREDS);$|\1if (vm_write) {\n\1\trc = security_remote_write(task, NULL);\n\1\tif (rc)\n\1\t\tgoto put_task_struct;\n\1}\n\n&|
        }
    }' \
    '^[[:space:]]*rc = security_remote_write(task, NULL);$'

# Mediate mount attribute changes before the mount is prepared or committed.
edit include/linux/lsm_hook_defs.h '^LSM_HOOK(int, 0, move_mount, const struct path \*from_path,$' \
    '/^LSM_HOOK(int, 0, move_mount, const struct path \*from_path,$/,/^LSM_HOOK(int, -EOPNOTSUPP, dentry_init_security,/ {
        s|^[[:space:]]*const struct path \*to_path)$|&\nLSM_HOOK(int, 0, mount_setattr, const struct path *path)|
    }' \
    '^LSM_HOOK(int, 0, mount_setattr, const struct path \*path)$'

edit include/linux/security.h '^int security_move_mount(const struct path \*from_path, const struct path \*to_path);$' \
    '/^int security_move_mount(const struct path \*from_path, const struct path \*to_path);$/,/^int security_dentry_init_security(struct dentry \*dentry, int mode,$/ {
        s|^int security_dentry_init_security(struct dentry \*dentry, int mode,$|int security_mount_setattr(const struct path *path);\n&|
    }' \
    '^int security_mount_setattr(const struct path \*path);$'
edit include/linux/security.h '^static inline int security_move_mount(const struct path \*from_path,$' \
    '/^static inline int security_move_mount(const struct path \*from_path,$/,/^static inline int security_path_notify(const struct path \*path, u64 mask,$/ {
        s|^static inline int security_path_notify(const struct path \*path, u64 mask,$|static inline int security_mount_setattr(const struct path *path)\n{\n\treturn 0;\n}\n\n&|
    }' \
    '^static inline int security_mount_setattr(const struct path \*path)$'

edit security/security.c '^int security_move_mount(const struct path \*from_path,$' \
    '/^int security_move_mount(const struct path \*from_path,$/,/^ \* security_path_notify() - Check if setting a watch is allowed$/ {
        s|^}$|}\n\n/**\n * security_mount_setattr() - Check permissions for changing mount attributes\n * @path: mount point\n *\n * Check permission before changing mount attributes.\n *\n * Return: Returns 0 if permission is granted.\n */\nint security_mount_setattr(const struct path *path)\n{\n\treturn call_int_hook(mount_setattr, path);\n}|
    }' \
    '^int security_mount_setattr(const struct path \*path)$'

edit fs/namespace.c '^static int do_mount_setattr(const struct path \*path, struct mount_kattr \*kattr)$' \
    '/^static int do_mount_setattr(const struct path \*path, struct mount_kattr \*kattr)$/,/^static int build_mount_idmapped(/ {
        s|^\([[:space:]]*\)err = mount_setattr_prepare(kattr, mnt);$|\1err = security_mount_setattr(path);\n\1if (err)\n\1\tgoto out;\n\n&|
    }' \
    '^[[:space:]]*err = security_mount_setattr(path);$'

# Mediate filesystem configuration before commands can create or reconfigure
# a superblock, and mount creation from any successfully configured context.
edit include/linux/lsm_hook_defs.h '^LSM_HOOK(int, -ENOPARAM, fs_context_parse_param, struct fs_context \*fc,$' \
    '/^LSM_HOOK(int, -ENOPARAM, fs_context_parse_param, struct fs_context \*fc,$/,/^LSM_HOOK(int, 0, sb_alloc_security,/ {
        s|^LSM_HOOK(int, 0, sb_alloc_security, struct super_block \*sb)$|LSM_HOOK(int, 0, fsconfig, struct fs_context *fc, unsigned int cmd)\n&|
    }' \
    '^LSM_HOOK(int, 0, fsconfig, struct fs_context \*fc, unsigned int cmd)$'
edit include/linux/lsm_hook_defs.h '^LSM_HOOK(int, 0, fsconfig, struct fs_context \*fc, unsigned int cmd)$' \
    '/^LSM_HOOK(int, 0, fsconfig, struct fs_context \*fc, unsigned int cmd)$/,/^LSM_HOOK(int, 0, sb_alloc_security,/ {
        s|^LSM_HOOK(int, 0, sb_alloc_security, struct super_block \*sb)$|LSM_HOOK(int, 0, fsmount, struct fs_context *fc)\n&|
    }' \
    '^LSM_HOOK(int, 0, fsmount, struct fs_context \*fc)$'

edit include/linux/security.h '^int security_fs_context_parse_param(struct fs_context \*fc, struct fs_parameter \*param);$' \
    '/^int security_fs_context_parse_param(struct fs_context \*fc, struct fs_parameter \*param);$/,/^int security_sb_alloc(struct super_block \*sb);$/ {
        s|^int security_sb_alloc(struct super_block \*sb);$|int security_fsconfig(struct fs_context *fc, unsigned int cmd);\n&|
    }' \
    '^int security_fsconfig(struct fs_context \*fc, unsigned int cmd);$'
edit include/linux/security.h '^int security_fsconfig(struct fs_context \*fc, unsigned int cmd);$' \
    '/^int security_fsconfig(struct fs_context \*fc, unsigned int cmd);$/,/^int security_sb_alloc(struct super_block \*sb);$/ {
        s|^int security_sb_alloc(struct super_block \*sb);$|int security_fsmount(struct fs_context *fc);\n&|
    }' \
    '^int security_fsmount(struct fs_context \*fc);$'

edit include/linux/security.h '^static inline int security_fs_context_parse_param(struct fs_context \*fc,$' \
    '/^static inline int security_fs_context_parse_param(struct fs_context \*fc,$/,/^static inline int security_sb_alloc(struct super_block \*sb)$/ {
        s|^static inline int security_sb_alloc(struct super_block \*sb)$|static inline int security_fsconfig(struct fs_context *fc, unsigned int cmd)\n{\n\treturn 0;\n}\n\n&|
    }' \
    '^static inline int security_fsconfig(struct fs_context \*fc, unsigned int cmd)$'
edit include/linux/security.h '^static inline int security_fsconfig(struct fs_context \*fc, unsigned int cmd)$' \
    '/^static inline int security_fsconfig(struct fs_context \*fc, unsigned int cmd)$/,/^static inline int security_sb_alloc(struct super_block \*sb)$/ {
        s|^static inline int security_sb_alloc(struct super_block \*sb)$|static inline int security_fsmount(struct fs_context *fc)\n{\n\treturn 0;\n}\n\n&|
    }' \
    '^static inline int security_fsmount(struct fs_context \*fc)$'

edit security/security.c '^int security_fs_context_parse_param(struct fs_context \*fc,$' \
    '/^int security_fs_context_parse_param(struct fs_context \*fc,$/,/^ \* security_sb_alloc() - Allocate a super_block LSM blob$/ {
        s|^}$|}\n\n/**\n * security_fsconfig() - Check permissions for filesystem configuration\n * @fc: filesystem context\n * @cmd: fsconfig command\n *\n * Check permission before applying a filesystem configuration command.\n *\n * Return: Returns 0 if permission is granted.\n */\nint security_fsconfig(struct fs_context *fc, unsigned int cmd)\n{\n\treturn call_int_hook(fsconfig, fc, cmd);\n}|
    }' \
    '^int security_fsconfig(struct fs_context \*fc, unsigned int cmd)$'
edit security/security.c '^int security_fsconfig(struct fs_context \*fc, unsigned int cmd)$' \
    '/^int security_fsconfig(struct fs_context \*fc, unsigned int cmd)$/,/^ \* security_sb_alloc() - Allocate a super_block LSM blob$/ {
        s|^}$|}\n\n/**\n * security_fsmount() - Check permissions for creating a mount\n * @fc: filesystem context\n *\n * Check permission before creating a mount from a filesystem context.\n *\n * Return: Returns 0 if permission is granted.\n */\nint security_fsmount(struct fs_context *fc)\n{\n\treturn call_int_hook(fsmount, fc);\n}|
    }' \
    '^int security_fsmount(struct fs_context \*fc)$'

edit fs/fsopen.c '^static int vfs_fsconfig_locked(struct fs_context \*fc, int cmd,$' \
    '/^static int vfs_fsconfig_locked(struct fs_context \*fc, int cmd,$/,/^ \* sys_fsconfig - Set parameters and trigger actions on a context$/ {
        s|^\([[:space:]]*\)switch (cmd) {$|\n\1ret = security_fsconfig(fc, cmd);\n\1if (ret)\n\1\treturn ret;\n\n&|
    }' \
    '^[[:space:]]*ret = security_fsconfig(fc, cmd);$'
edit fs/namespace.c '^SYSCALL_DEFINE3(fsmount, int, fs_fd, unsigned int, flags,$' \
    '/^SYSCALL_DEFINE3(fsmount, int, fs_fd, unsigned int, flags,$/,/^static inline int vfs_move_mount(/ {
        s|^\([[:space:]]*\)if (fc->sb_flags & SB_MANDLOCK)$|\1ret = security_fsmount(fc);\n\1if (ret)\n\1\treturn ret;\n\n&|
    }' \
    '^[[:space:]]*ret = security_fsmount(fc);$'

# A failed GUP lookup has no page to release.  Check the VMA recovered for
# vm_ops->access separately from the normal page-backed write path above.
edit mm/memory.c '^static int __access_remote_vm(struct mm_struct \*mm, unsigned long addr,$' \
    '/^static int __access_remote_vm(struct mm_struct \*mm, unsigned long addr,$/,/^int access_remote_vm(struct mm_struct \*mm, unsigned long addr,$/ {
        /^[[:space:]]*if (IS_ERR(page)) {$/,/^[[:space:]]*} else {$/ {
            s|^\([[:space:]]*\)bytes = 0;$|\1if (write \&\& security_remote_write(NULL, vma))\n\1\tbreak;\n\n&|
        }
    }' \
    '^[[:space:]]*if (write && security_remote_write(NULL, vma))$'
