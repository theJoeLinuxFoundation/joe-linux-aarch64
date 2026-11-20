// SPDX-License-Identifier: GPL-2.0
/*
 * joe: the joe Linux security module.
 *
 * Three rules, all about privileged processes, which here means a process with
 * any global user id equal to 0 or with any capability in its permitted set in
 * the initial user namespace:
 *
 *  1. A privileged process only executes sealed code. A file is sealed when
 *     its contents are protected by fs-verity and it carries an xattr with a
 *     signature, by a key compiled into this kernel, over its verity digest
 *     and its declared operations. This covers the program itself, every
 *     library it maps, kernel modules it loads, and (through a query that
 *     joe's interpreters make before reading a script) every script.
 *
 *  2. A privileged process cannot create executable memory that is not a
 *     read-only mapping of a sealed file: no anonymous executable memory, no
 *     writable executable mappings, no making modified memory executable.
 *     That is what a just-in-time compiler needs, so none can run privileged.
 *
 *  3. A privileged process is confined to the operations its executable
 *     declares: which capabilities it uses, whether it uses the network, where
 *     it writes, what it runs. Declarations are part of what is signed.
 *
 * Unprivileged processes are not affected at all; ordinary Unix permissions
 * already confine them.
 *
 * The module starts in log mode unless "joe=enforce" is on the kernel command
 * line or it was built to enforce by default. Writing 1 to
 * /sys/kernel/security/joe/enforce switches to enforcing; nothing switches
 * back.
 */

#define pr_fmt(fmt) "joe: " fmt

#include <linux/binfmts.h>
#include <linux/capability.h>
#include <linux/cred.h>
#include <linux/dcache.h>
#include <linux/fs.h>
#include <linux/fs_context.h>
#include <linux/fsverity.h>
#include <linux/ipc.h>
#include <linux/kernel_read_file.h>
#include <linux/lsm_hooks.h>
#include <linux/mm.h>
#include <linux/mman.h>
#include <linux/mount.h>
#include <linux/mutex.h>
#include <linux/net.h>
#include <linux/path.h>
#include <linux/pid.h>
#include <linux/ptrace.h>
#include <linux/ratelimit.h>
#include <linux/rcupdate.h>
#include <linux/refcount.h>
#include <linux/sched/signal.h>
#include <linux/security.h>
#include <linux/slab.h>
#include <linux/socket.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/user_namespace.h>
#include <linux/xattr.h>
#include <crypto/sha2.h>
#include <crypto/sig.h>
#include <uapi/linux/fsverity.h>
#include <uapi/linux/lsm.h>
#include <uapi/linux/mount.h>

/* Generated at build time: the code-signing public keys this kernel trusts. */
#include "joe_keys.h"

#define JOE_XATTR		"security.joe"
#define JOE_MAGIC		"JOE1"
#define JOE_MAGIC_LEN		4
#define JOE_DIGEST_LEN		32
#define JOE_SIG_LEN		64
#define JOE_OPS_MAX		8192
#define JOE_SEAL_MAX		(JOE_MAGIC_LEN + 2 + JOE_OPS_MAX + JOE_SIG_LEN)
#define JOE_MAX_PATHS		64

/*
 * The query an interpreter makes on an open script before running it:
 * ioctl(fd, JOE_IOC_CHECK_SCRIPT). This module answers from its file_ioctl
 * hook, which runs before the file system sees the request: a privileged
 * caller holding an unsealed file gets EACCES. In every other case the hook
 * lets the request through, no file system implements it, and the caller gets
 * ENOTTY, exactly as on a kernel without this module. An interpreter
 * therefore refuses a script if and only if errno is EACCES.
 *
 * The kernel's own AT_EXECVE_CHECK is answered too, but it also requires the
 * execute permission bit, which files that are sourced or imported (shell
 * fragments, Python modules) do not have.
 */
#define JOE_IOC_CHECK_SCRIPT	_IO(0xE7, 0x01)

static bool joe_enforce = IS_ENABLED(CONFIG_SECURITY_JOE_ENFORCE);

/* ------------------------------------------------------------------------ */
/* Declared operations                                                       */
/* ------------------------------------------------------------------------ */

enum joe_flag {
	JOE_ALL,		/* everything below */
	JOE_NET,		/* sockets other than local and netlink */
	JOE_ROOT_IPC,
	JOE_MOUNT,
	JOE_MODULE,
	JOE_PTRACE,
	JOE_BPF,
	JOE_WRITE_ANY,
	JOE_EXEC_ANY,
	JOE_FLAG_COUNT,
};

struct joe_ops {
	refcount_t refs;
	struct rcu_head rcu;
	unsigned long flags;
	u64 caps;
	/* What has already been reported in log mode, to report each once. */
	unsigned long reported_flags;
	u64 reported_caps;
	bool undeclared;
	unsigned int nwrite;
	unsigned int nexec;
	const char *write[JOE_MAX_PATHS];	/* path prefixes */
	const char *exec[JOE_MAX_PATHS];	/* exact paths */
	char *name;				/* the executable, for messages */
	char text[];				/* backing store for the paths */
};

static void joe_ops_free(struct rcu_head *rcu)
{
	struct joe_ops *ops = container_of(rcu, struct joe_ops, rcu);

	kfree(ops->name);
	kfree(ops);
}

static struct joe_ops *joe_ops_get(struct joe_ops *ops)
{
	if (ops)
		refcount_inc(&ops->refs);
	return ops;
}

static void joe_ops_put(struct joe_ops *ops)
{
	if (ops && refcount_dec_and_test(&ops->refs))
		call_rcu(&ops->rcu, joe_ops_free);
}

/*
 * Parses the declaration text: one operation per line.
 *
 *   all            write:/path/prefix    exec:/path/to/program
 *   net            write:*               exec:*
 *   root-ipc       cap:<number>          cap:*
 *   mount          module                ptrace
 *   bpf            undeclared
 *
 * Unknown lines are ignored so that a newer package still loads on an older
 * kernel, where it simply gets fewer permissions than it asked for.
 */
static struct joe_ops *joe_ops_parse(const u8 *text, size_t len)
{
	struct joe_ops *ops;
	char *line, *next;

	ops = kzalloc(sizeof(*ops) + len + 1, GFP_KERNEL);
	if (!ops)
		return NULL;
	refcount_set(&ops->refs, 1);
	memcpy(ops->text, text, len);
	ops->text[len] = '\0';

	for (line = ops->text; line && *line; line = next) {
		next = strchr(line, '\n');
		if (next)
			*next++ = '\0';

		if (!strcmp(line, "all")) {
			__set_bit(JOE_ALL, &ops->flags);
		} else if (!strcmp(line, "net")) {
			__set_bit(JOE_NET, &ops->flags);
		} else if (!strcmp(line, "root-ipc")) {
			__set_bit(JOE_ROOT_IPC, &ops->flags);
		} else if (!strcmp(line, "undeclared")) {
			ops->undeclared = true;
		} else if (!strcmp(line, "mount")) {
			__set_bit(JOE_MOUNT, &ops->flags);
		} else if (!strcmp(line, "module")) {
			__set_bit(JOE_MODULE, &ops->flags);
		} else if (!strcmp(line, "ptrace")) {
			__set_bit(JOE_PTRACE, &ops->flags);
		} else if (!strcmp(line, "bpf")) {
			__set_bit(JOE_BPF, &ops->flags);
		} else if (!strcmp(line, "cap:*")) {
			ops->caps = ~0ULL;
		} else if (!strncmp(line, "cap:", 4)) {
			unsigned int cap;

			if (!kstrtouint(line + 4, 10, &cap) && cap < 64)
				ops->caps |= BIT_ULL(cap);
		} else if (!strcmp(line, "write:*")) {
			__set_bit(JOE_WRITE_ANY, &ops->flags);
		} else if (!strncmp(line, "write:/", 7)) {
			if (ops->nwrite < JOE_MAX_PATHS)
				ops->write[ops->nwrite++] = line + 6;
		} else if (!strcmp(line, "exec:*")) {
			__set_bit(JOE_EXEC_ANY, &ops->flags);
		} else if (!strncmp(line, "exec:/", 6)) {
			if (ops->nexec < JOE_MAX_PATHS)
				ops->exec[ops->nexec++] = line + 5;
		}
	}
	return ops;
}

static bool joe_ops_allows(const struct joe_ops *ops, enum joe_flag flag)
{
	return test_bit(JOE_ALL, &ops->flags) || test_bit(flag, &ops->flags);
}

/* ------------------------------------------------------------------------ */
/* Per-object state                                                          */
/* ------------------------------------------------------------------------ */

enum joe_seal_state { JOE_UNKNOWN, JOE_SEALED, JOE_UNSEALED };

struct joe_inode {
	u8 state;
	/* Log mode: bit JOE_REPORTED_UNSEALED once this file was reported. */
	unsigned long reported;
	struct joe_ops __rcu *ops;
};

#define JOE_REPORTED_UNSEALED 0

struct joe_cred {
	/*
	 * The declarations of the program this credential runs. NULL means
	 * unconfined: kernel threads, processes started before any sealed
	 * program was executed, and unprivileged processes.
	 */
	struct joe_ops *ops;
};

struct joe_file {
	/* The owner that asynchronous SIGIO/SIGURG signals are sent for. */
	struct joe_ops *fown_ops;
	struct pid *fown_tgid;
};

static struct lsm_blob_sizes joe_blob_sizes __ro_after_init = {
	.lbs_cred = sizeof(struct joe_cred),
	.lbs_file = sizeof(struct joe_file),
	.lbs_inode = sizeof(struct joe_inode),
};

static struct joe_inode *joe_inode(const struct inode *inode)
{
	return inode->i_security + joe_blob_sizes.lbs_inode;
}

static struct joe_file *joe_file(const struct file *file)
{
	return file->f_security + joe_blob_sizes.lbs_file;
}

static struct joe_cred *joe_cred(const struct cred *cred)
{
	return cred->security + joe_blob_sizes.lbs_cred;
}

static bool joe_root_cred(const struct cred *cred)
{
	return uid_eq(cred->uid, GLOBAL_ROOT_UID) ||
	       uid_eq(cred->euid, GLOBAL_ROOT_UID) ||
	       uid_eq(cred->suid, GLOBAL_ROOT_UID) ||
	       uid_eq(cred->fsuid, GLOBAL_ROOT_UID);
}

static bool joe_privileged(const struct cred *cred)
{
	/* Root keeps its global identity in a child user namespace. */
	return joe_root_cred(cred) ||
	       (cred->user_ns == &init_user_ns && !cap_isclear(cred->cap_permitted));
}

static bool joe_task_privileged(struct task_struct *task)
{
	bool privileged;

	rcu_read_lock();
	privileged = joe_privileged(__task_cred(task));
	rcu_read_unlock();
	return privileged;
}

static bool joe_task_root(struct task_struct *task)
{
	bool root;

	rcu_read_lock();
	root = joe_root_cred(__task_cred(task));
	rcu_read_unlock();
	return root;
}

/* ------------------------------------------------------------------------ */
/* Reporting                                                                 */
/* ------------------------------------------------------------------------ */

/*
 * Reports a violation and returns the value the hook should return. The
 * format is stable, because in log mode these lines are the raw material from
 * which declarations are written: op=<operation> arg=<detail> exe=<program>.
 *
 * Log mode reports everything, below the console's level: nothing is wrong
 * yet and a missing line would be a missing declaration. The exception is an
 * unsealed file, which is reported the first time privileged code uses it
 * (joe_require_sealed). Denials are warnings, rate limited so that a
 * misbehaving program cannot flood the log.
 */
static int joe_violation(const struct joe_ops *ops, const char *op,
			 const char *arg, int err)
{
	const char *exe = ops && ops->name ? ops->name : "-";

	if (!arg)
		arg = "-";
	if (joe_enforce)
		pr_warn_ratelimited("denied op=%s arg=%s exe=%s comm=%s pid=%d\n",
				    op, arg, exe, current->comm, task_pid_nr(current));
	else
		pr_info("would-deny op=%s arg=%s exe=%s comm=%s pid=%d\n",
			op, arg, exe, current->comm, task_pid_nr(current));
	return joe_enforce ? err : 0;
}

/* A flag-type violation, reported once per program in log mode. */
static int joe_flag_violation(struct joe_ops *ops, enum joe_flag flag,
			      const char *op, const char *arg, int err)
{
	if (!joe_enforce && test_and_set_bit(flag, &ops->reported_flags))
		return 0;
	return joe_violation(ops, op, arg, err);
}

/* ------------------------------------------------------------------------ */
/* Seals                                                                     */
/* ------------------------------------------------------------------------ */

static DEFINE_MUTEX(joe_verify_lock);
static struct crypto_sig *joe_tfm[ARRAY_SIZE(joe_keys)];

/*
 * The verifiers are set up once, late in boot and before any program runs.
 * Allocating one may make the kernel try to load a module, which runs
 * modprobe, whose execution comes back here to be checked; so it must never
 * happen while a seal is being verified.
 */
static int __init joe_init_keys(void)
{
	unsigned int i, ready = 0;

	for (i = 0; i < ARRAY_SIZE(joe_keys); i++) {
		struct crypto_sig *tfm = crypto_alloc_sig("p1363(ecdsa-nist-p256)", 0, 0);

		if (IS_ERR(tfm)) {
			pr_err("no ECDSA P-256 verifier: %ld\n", PTR_ERR(tfm));
			continue;
		}
		if (crypto_sig_set_pubkey(tfm, joe_keys[i], sizeof(joe_keys[i]))) {
			pr_err("trusted key %u is not a valid P-256 point\n", i);
			crypto_free_sig(tfm);
			continue;
		}
		WRITE_ONCE(joe_tfm[i], tfm);
		ready++;
	}
	pr_info("%u of %zu trusted key(s) ready\n", ready, ARRAY_SIZE(joe_keys));
	return 0;
}
late_initcall(joe_init_keys);

static bool joe_signature_valid(const u8 *digest, const u8 *sig)
{
	unsigned int i;

	lockdep_assert_held(&joe_verify_lock);
	for (i = 0; i < ARRAY_SIZE(joe_keys); i++) {
		struct crypto_sig *tfm = READ_ONCE(joe_tfm[i]);

		if (tfm && !crypto_sig_verify(tfm, sig, JOE_SIG_LEN, digest, SHA256_DIGEST_SIZE))
			return true;
	}
	return false;
}

/*
 * Reads and checks the seal of a file. The seal xattr is
 *
 *     "JOE1"  le16 ops_len  ops[ops_len]  signature[64]
 *
 * and the signature is ECDSA P-256 over SHA-256 of
 *
 *     "JOE1"  verity_digest[32]  le16 ops_len  ops[ops_len]
 *
 * so it binds the declarations to one exact file content.
 */
static struct joe_ops *joe_read_seal(struct file *file)
{
	struct inode *inode = file_inode(file);
	u8 verity[FS_VERITY_MAX_DIGEST_SIZE];
	u8 hash[SHA256_DIGEST_SIZE];
	struct sha256_ctx ctx;
	struct joe_ops *ops = NULL;
	u8 alg = 0;
	u8 *seal;
	ssize_t len;
	u16 ops_len;

	if (!S_ISREG(inode->i_mode))
		return NULL;
	if (fsverity_get_digest(inode, verity, &alg, NULL) != JOE_DIGEST_LEN ||
	    alg != FS_VERITY_HASH_ALG_SHA256)
		return NULL;

	seal = kmalloc(JOE_SEAL_MAX, GFP_KERNEL);
	if (!seal)
		return NULL;
	len = __vfs_getxattr(file->f_path.dentry, inode, JOE_XATTR, seal, JOE_SEAL_MAX);
	if (len < JOE_MAGIC_LEN + 2 + JOE_SIG_LEN || memcmp(seal, JOE_MAGIC, JOE_MAGIC_LEN))
		goto out;
	ops_len = seal[JOE_MAGIC_LEN] | (seal[JOE_MAGIC_LEN + 1] << 8);
	if (ops_len > JOE_OPS_MAX || len != JOE_MAGIC_LEN + 2 + ops_len + JOE_SIG_LEN)
		goto out;

	sha256_init(&ctx);
	sha256_update(&ctx, JOE_MAGIC, JOE_MAGIC_LEN);
	sha256_update(&ctx, verity, JOE_DIGEST_LEN);
	sha256_update(&ctx, seal + JOE_MAGIC_LEN, 2 + ops_len);
	sha256_final(&ctx, hash);

	if (joe_signature_valid(hash, seal + JOE_MAGIC_LEN + 2 + ops_len))
		ops = joe_ops_parse(seal + JOE_MAGIC_LEN + 2, ops_len);
out:
	kfree(seal);
	return ops;
}

/*
 * Returns the declarations of a sealed file with a reference held, or NULL
 * if the file is not sealed. The verdict is cached on the inode; fs-verity
 * guarantees the contents cannot change, and replacing the xattr drops the
 * cache.
 */
static struct joe_ops *joe_sealed(struct file *file)
{
	struct joe_inode *blob;
	struct joe_ops *ops;

	if (!file)
		return NULL;
	blob = joe_inode(file_inode(file));

	if (READ_ONCE(blob->state) == JOE_UNKNOWN) {
		mutex_lock(&joe_verify_lock);
		if (blob->state == JOE_UNKNOWN) {
			ops = joe_read_seal(file);
			if (ops) {
				char *buf = (char *)__get_free_page(GFP_KERNEL);

				if (buf) {
					char *p = d_path(&file->f_path, buf, PAGE_SIZE);

					if (!IS_ERR(p))
						ops->name = kstrdup(p, GFP_KERNEL);
					free_page((unsigned long)buf);
				}
			}
			rcu_assign_pointer(blob->ops, ops);
			WRITE_ONCE(blob->state, ops ? JOE_SEALED : JOE_UNSEALED);
		}
		mutex_unlock(&joe_verify_lock);
	}

	rcu_read_lock();
	ops = rcu_dereference(blob->ops);
	if (ops && !refcount_inc_not_zero(&ops->refs))
		ops = NULL;
	rcu_read_unlock();
	return ops;
}

static void joe_forget(struct inode *inode)
{
	struct joe_inode *blob = joe_inode(inode);
	struct joe_ops *old;

	mutex_lock(&joe_verify_lock);
	old = rcu_replace_pointer(blob->ops, NULL, lockdep_is_held(&joe_verify_lock));
	WRITE_ONCE(blob->state, JOE_UNKNOWN);
	clear_bit(JOE_REPORTED_UNSEALED, &blob->reported);
	mutex_unlock(&joe_verify_lock);
	joe_ops_put(old);
}

/* Describes a file for a report. The caller frees the result with free_page. */
static const char *joe_file_name(struct file *file, char **page)
{
	char *p;

	*page = (char *)__get_free_page(GFP_KERNEL);
	if (!*page)
		return "?";
	p = d_path(&file->f_path, *page, PAGE_SIZE);
	return IS_ERR(p) ? "?" : p;
}

/* Rule 1 for one file: privileged code must be sealed. */
static int joe_require_sealed(struct file *file, const char *op)
{
	struct joe_ops *ops = joe_sealed(file);
	const char *name;
	char *page;
	int ret;

	if (ops) {
		joe_ops_put(ops);
		return 0;
	}
	/*
	 * Where nothing is sealed yet (a live medium, an image before its
	 * first boot has sealed it) every exec and every library of every root
	 * process would be reported, again each time, and the kernel log would
	 * lose the messages that matter. That a file is unsealed is said once.
	 */
	if (!joe_enforce &&
	    test_and_set_bit(JOE_REPORTED_UNSEALED, &joe_inode(file_inode(file))->reported))
		return 0;
	name = joe_file_name(file, &page);
	ret = joe_violation(joe_cred(current_cred())->ops, op, name, -EACCES);
	if (page)
		free_page((unsigned long)page);
	return ret;
}

static int joe_refuse_undeclared(struct file *file, struct joe_ops *caller)
{
	const char *name;
	char *page;
	int ret;

	name = joe_file_name(file, &page);
	ret = joe_violation(caller, "undeclared", name, -EACCES);
	if (page)
		free_page((unsigned long)page);
	return ret;
}

/* ------------------------------------------------------------------------ */
/* Rule 1 and rule 2: execution                                              */
/* ------------------------------------------------------------------------ */

/* Every file in an exec chain: the script, then its interpreter. */
static int joe_bprm_check_security(struct linux_binprm *bprm)
{
	const struct cred *cred = current_cred();
	struct joe_ops *ops = joe_cred(cred)->ops;
	struct joe_ops *target = NULL;
	const char *name;
	char *page = NULL;
	unsigned int i;
	int ret;

	if (!joe_privileged(cred))
		return 0;
	ret = joe_require_sealed(bprm->file, "exec-unsealed");
	if (ret)
		return ret;

	/*
	 * Rule 3: may this program run that one? Asked once per exec, about
	 * the file that was named, not about the interpreter of a script.
	 */
	if (bprm->interp != bprm->filename)
		return 0;
	target = joe_sealed(bprm->file);
	if (target && target->undeclared &&
	    !(ops && test_bit(JOE_ALL, &ops->flags))) {
		ret = joe_refuse_undeclared(bprm->file, ops);
		goto out_target;
	}
	if (!ops || joe_ops_allows(ops, JOE_EXEC_ANY))
		goto out_target;
	name = joe_file_name(bprm->file, &page);
	for (i = 0; i < ops->nexec; i++)
		if (!strcmp(ops->exec[i], name))
			goto out;
	ret = joe_violation(ops, "exec", name, -EACCES);
out:
	if (page)
		free_page((unsigned long)page);
out_target:
	joe_ops_put(target);
	return ret;
}

static int joe_file_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	if (cmd != JOE_IOC_CHECK_SCRIPT || !joe_privileged(current_cred()))
		return 0;
	return joe_require_sealed(file, "script-unsealed");
}

/* The same question asked through the kernel's own AT_EXECVE_CHECK. */
static int joe_bprm_creds_for_exec(struct linux_binprm *bprm)
{
	if (!bprm->is_check)
		return 0;
	return joe_bprm_check_security(bprm);
}

/*
 * The new credentials are known. A process that becomes or stays privileged
 * takes on the declarations of the program it now runs; one that is
 * unprivileged carries none.
 */
static int joe_bprm_creds_from_file(struct linux_binprm *bprm, const struct file *file)
{
	struct joe_cred *jc = joe_cred(bprm->cred);
	struct joe_ops *ops = NULL;
	int ret = 0;

	if (joe_privileged(bprm->cred)) {
		ops = joe_sealed((struct file *)file);
		if (!ops) {
			ret = joe_require_sealed((struct file *)file, "exec-unsealed");
		} else if (ops->undeclared) {
			if (jc->ops && test_bit(JOE_ALL, &jc->ops->flags)) {
				/* Only an undeclared program inherits an all caller. */
				joe_ops_put(ops);
				ops = joe_ops_get(jc->ops);
			} else if (!joe_privileged(current_cred())) {
				/* The earlier check saw an unprivileged caller. Do not
				 * let a setuid/capability transition bypass this rule. */
				ret = joe_refuse_undeclared((struct file *)file, jc->ops);
			}
		}
	}
	joe_ops_put(jc->ops);
	jc->ops = ops;
	return ret;
}

static int joe_mmap_file(struct file *file, unsigned long reqprot,
			 unsigned long prot, unsigned long flags)
{
	const struct cred *cred = current_cred();

	if (!(prot & PROT_EXEC) || !joe_privileged(cred))
		return 0;
	if (!file)
		return joe_violation(joe_cred(cred)->ops, "jit", "anonymous-executable-memory", -EACCES);
	if (prot & PROT_WRITE)
		return joe_violation(joe_cred(cred)->ops, "jit", "writable-executable-mapping", -EACCES);
	return joe_require_sealed(file, "map-unsealed");
}

static int joe_file_mprotect(struct vm_area_struct *vma, unsigned long reqprot,
			     unsigned long prot)
{
	const struct cred *cred = current_cred();

	if (!joe_privileged(cred))
		return 0;
	/* Code may not become writable... */
	if ((vma->vm_flags & VM_EXEC) && (prot & PROT_WRITE))
		return joe_violation(joe_cred(cred)->ops, "jit", "executable-made-writable", -EACCES);
	if (!(prot & PROT_EXEC) || (vma->vm_flags & VM_EXEC))
		return 0;
	/* ...and only untouched pages of a sealed file may become code. */
	if (!vma->vm_file)
		return joe_violation(joe_cred(cred)->ops, "jit", "anonymous-memory-made-executable", -EACCES);
	if (vma->anon_vma || (prot & PROT_WRITE))
		return joe_violation(joe_cred(cred)->ops, "jit", "modified-memory-made-executable", -EACCES);
	return joe_require_sealed(vma->vm_file, "map-unsealed");
}

static int joe_kernel_read_file(struct file *file, enum kernel_read_file_id id,
				bool contents)
{
	struct joe_ops *ops = joe_cred(current_cred())->ops;

	switch (id) {
	case READING_MODULE:
	case READING_MODULE_COMPRESSED:
		if (ops && !joe_ops_allows(ops, JOE_MODULE))
			return joe_flag_violation(ops, JOE_MODULE, "module", "load", -EPERM);
		return joe_require_sealed(file, "module-unsealed");
	case READING_KEXEC_IMAGE:
	case READING_KEXEC_INITRAMFS:
		return joe_violation(ops, "kexec", "-", -EPERM);
	default:
		return 0;
	}
}

static int joe_kernel_load_data(enum kernel_load_data_id id, bool contents)
{
	/* A module or kernel passed as a buffer has no file to be sealed. */
	if (id == LOADING_MODULE || id == LOADING_KEXEC_IMAGE || id == LOADING_KEXEC_INITRAMFS)
		return joe_violation(joe_cred(current_cred())->ops, "load-unsealed",
				     kernel_load_data_id_str(id), -EPERM);
	return 0;
}

/* ------------------------------------------------------------------------ */
/* Rule 3: declared operations                                               */
/* ------------------------------------------------------------------------ */

static int joe_capable(const struct cred *cred, struct user_namespace *ns,
		       int cap, unsigned int opts)
{
	struct joe_ops *ops = joe_cred(cred)->ops;
	char arg[8];

	/* A capability over a user namespace is not privilege over the system. */
	if (!ops || ns != &init_user_ns || test_bit(JOE_ALL, &ops->flags))
		return 0;
	if (cap < 64 && (ops->caps & BIT_ULL(cap)))
		return 0;
	if (!joe_enforce) {
		/* Probes are not uses; report each real use once. */
		if ((opts & CAP_OPT_NOAUDIT) || cap >= 64 || (ops->reported_caps & BIT_ULL(cap)))
			return 0;
		ops->reported_caps |= BIT_ULL(cap);
	} else if (opts & CAP_OPT_NOAUDIT) {
		return -EPERM;
	}
	snprintf(arg, sizeof(arg), "%d", cap);
	return joe_violation(ops, "cap", arg, -EPERM);
}

static int joe_task_kill(struct task_struct *p, struct kernel_siginfo *info,
			 int sig, const struct cred *cred)
{
	struct joe_ops *ops;

	if (!sig || info == SEND_SIG_PRIV ||
	    (info != SEND_SIG_NOINFO && SI_FROMKERNEL(info)))
		return 0;
	if (!cred) {
		if (same_thread_group(current, p))
			return 0;
		cred = current_cred();
	}
	ops = joe_cred(cred)->ops;
	if (!ops || !joe_privileged(cred) || joe_ops_allows(ops, JOE_ROOT_IPC) ||
	    !joe_task_root(p))
		return 0;
	return joe_flag_violation(ops, JOE_ROOT_IPC, "root-ipc", "signal", -EPERM);
}

static void joe_file_set_fowner(struct file *file)
{
	const struct cred *cred = current_cred();
	struct joe_file *jf = joe_file(file);
	struct joe_ops *old_ops = jf->fown_ops;
	struct pid *old_tgid = jf->fown_tgid;

	jf->fown_ops = NULL;
	jf->fown_tgid = NULL;
	if (joe_privileged(cred) && joe_cred(cred)->ops) {
		jf->fown_ops = joe_ops_get(joe_cred(cred)->ops);
		jf->fown_tgid = get_pid(task_tgid(current));
	}
	joe_ops_put(old_ops);
	put_pid(old_tgid);
}

static int joe_file_send_sigiotask(struct task_struct *tsk,
				   struct fown_struct *fown, int sig)
{
	struct joe_file *jf = joe_file(fown->file);
	struct joe_ops *ops = jf->fown_ops;

	if (!ops || joe_ops_allows(ops, JOE_ROOT_IPC) ||
	    jf->fown_tgid == task_tgid(tsk) || !joe_task_root(tsk))
		return 0;
	return joe_flag_violation(ops, JOE_ROOT_IPC, "root-ipc", "sigio", -EPERM);
}

static int joe_ipc_check(struct kern_ipc_perm *ipcp, const char *arg)
{
	const struct cred *cred = current_cred();
	struct joe_ops *ops = joe_cred(cred)->ops;

	/* IPC_INFO and the related commands have no target object. */
	if (!ipcp || !ops || !joe_privileged(cred) || joe_ops_allows(ops, JOE_ROOT_IPC) ||
	    (!uid_eq(ipcp->uid, GLOBAL_ROOT_UID) &&
	     !uid_eq(ipcp->cuid, GLOBAL_ROOT_UID)))
		return 0;
	return joe_flag_violation(ops, JOE_ROOT_IPC, "root-ipc", arg, -EPERM);
}

static int joe_ipc_permission(struct kern_ipc_perm *ipcp, short flag)
{
	return joe_ipc_check(ipcp, "sysv");
}

/* Object control does not necessarily go through ipc_permission. */
static int joe_shm_shmctl(struct kern_ipc_perm *ipcp, int cmd)
{
	return joe_ipc_check(ipcp, "shmctl");
}

static int joe_msg_queue_msgctl(struct kern_ipc_perm *ipcp, int cmd)
{
	return joe_ipc_check(ipcp, "msgctl");
}

static int joe_sem_semctl(struct kern_ipc_perm *ipcp, int cmd)
{
	return joe_ipc_check(ipcp, "semctl");
}

static int joe_userns_create(const struct cred *cred)
{
	/* Global root remains confined after the transition. A capability-only
	 * process would instead lose its declarations when its old capability set
	 * was replaced by a full set in the new namespace. */
	if (!joe_privileged(cred) || joe_root_cred(cred))
		return 0;
	return joe_violation(joe_cred(cred)->ops, "userns", "create", -EPERM);
}

static int joe_socket_create(int family, int type, int protocol, int kern)
{
	const struct cred *cred = current_cred();
	struct joe_ops *ops = joe_cred(cred)->ops;
	char arg[8];

	if (kern || !ops || !joe_privileged(cred))
		return 0;
	/* Talking to local services and to the kernel is not "the network". */
	if (family == AF_UNIX || family == AF_NETLINK || joe_ops_allows(ops, JOE_NET))
		return 0;
	snprintf(arg, sizeof(arg), "%d", family);
	return joe_flag_violation(ops, JOE_NET, "net", arg, -EACCES);
}

/* Whether writes under this path are declared. */
static bool joe_may_write(const struct joe_ops *ops, const char *path)
{
	unsigned int i;

	if (joe_ops_allows(ops, JOE_WRITE_ANY))
		return true;
	for (i = 0; i < ops->nwrite; i++) {
		size_t n = strlen(ops->write[i]);

		if (!strncmp(path, ops->write[i], n) &&
		    (path[n] == '\0' || path[n] == '/' || ops->write[i][n - 1] == '/'))
			return true;
	}
	return false;
}

/*
 * Write declarations concern persistent storage. Only filesystems known to
 * contain no state that outlives the boot are exempt; network, stacked and
 * unknown filesystems are persistent, fail closed.
 */
static bool joe_persistent(const struct super_block *sb)
{
	static const char * const volatile_fs[] = {
		"proc", "sysfs", "tmpfs", "ramfs", "rootfs", "devtmpfs",
		"devpts", "cgroup", "cgroup2", "securityfs", "debugfs",
		"tracefs", "configfs", "sockfs", "pipefs", "anon_inodefs",
		"mqueue", "hugetlbfs", "fusectl", "rpc_pipefs", "autofs",
		"binfmt_misc", "bpf",
	};
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(volatile_fs); i++)
		if (!strcmp(sb->s_type->name, volatile_fs[i]))
			return false;
	return true;
}

static int joe_check_write_path(const struct path *dir, struct dentry *dentry,
				const char *op, bool force)
{
	const struct cred *cred = current_cred();
	struct joe_ops *ops = joe_cred(cred)->ops;
	char *page, *p;
	int ret = 0;

	if (!ops || !joe_privileged(cred) || joe_ops_allows(ops, JOE_WRITE_ANY))
		return 0;
	if (!force && !joe_persistent(dir->dentry->d_sb))
		return 0;
	page = (char *)__get_free_page(GFP_KERNEL);
	if (!page)
		return joe_enforce ? -ENOMEM : 0;
	p = d_path(dir, page, PAGE_SIZE);
	if (IS_ERR(p)) {
		ret = joe_enforce ? PTR_ERR(p) : 0;
	} else if (dentry) {
		/* The object named by dentry inside the directory. */
		size_t dlen = strlen(p), nlen = dentry->d_name.len;

		memmove(page, p, dlen);
		if (dlen + 1 + nlen + 1 <= PAGE_SIZE) {
			if (dlen > 1)
				page[dlen++] = '/';
			memcpy(page + dlen, dentry->d_name.name, nlen);
			page[dlen + nlen] = '\0';
		} else {
			page[dlen] = '\0';
		}
		if (!joe_may_write(ops, page))
			ret = joe_violation(ops, op, page, -EACCES);
	} else if (!joe_may_write(ops, p)) {
		ret = joe_violation(ops, op, p, -EACCES);
	}
	free_page((unsigned long)page);
	return ret;
}

static int joe_check_write(const struct path *dir, struct dentry *dentry, const char *op)
{
	return joe_check_write_path(dir, dentry, op, false);
}

static int joe_file_open(struct file *file)
{
	umode_t mode = file_inode(file)->i_mode;

	if (!(file->f_mode & FMODE_WRITE) || (!S_ISREG(mode) && !S_ISBLK(mode)))
		return 0;
	/* Block writes persist even when the device node lives in devtmpfs. */
	return joe_check_write_path(&file->f_path, NULL, "write", S_ISBLK(mode));
}

static int joe_path_unlink(const struct path *dir, struct dentry *dentry)
{
	return joe_check_write(dir, dentry, "write");
}

static int joe_path_mkdir(const struct path *dir, struct dentry *dentry, umode_t mode)
{
	return joe_check_write(dir, dentry, "write");
}

static int joe_path_rmdir(const struct path *dir, struct dentry *dentry)
{
	return joe_check_write(dir, dentry, "write");
}

static int joe_path_mknod(const struct path *dir, struct dentry *dentry,
			  umode_t mode, unsigned int dev)
{
	return joe_check_write(dir, dentry, "write");
}

static int joe_path_symlink(const struct path *dir, struct dentry *dentry,
			    const char *old_name)
{
	return joe_check_write(dir, dentry, "write");
}

static int joe_path_link(struct dentry *old_dentry, const struct path *new_dir,
			 struct dentry *new_dentry)
{
	return joe_check_write(new_dir, new_dentry, "write");
}

static int joe_path_rename(const struct path *old_dir, struct dentry *old_dentry,
			   const struct path *new_dir, struct dentry *new_dentry,
			   unsigned int flags)
{
	int ret = joe_check_write(old_dir, old_dentry, "write");

	return ret ? ret : joe_check_write(new_dir, new_dentry, "write");
}

static int joe_path_truncate(const struct path *path)
{
	return joe_check_write(path, NULL, "write");
}

static int joe_check_mount(const char *arg)
{
	const struct cred *cred = current_cred();
	struct joe_ops *ops = joe_cred(cred)->ops;

	if (!ops || !joe_privileged(cred) || joe_ops_allows(ops, JOE_MOUNT))
		return 0;
	return joe_flag_violation(ops, JOE_MOUNT, "mount", arg, -EPERM);
}

static int joe_sb_mount(const char *dev_name, const struct path *path,
			const char *type, unsigned long flags, void *data)
{
	return joe_check_mount(type);
}

static int joe_sb_kern_mount(const struct super_block *sb)
{
	/* FSCONFIG_CMD_CREATE reaches here even when no parameters were set. */
	return joe_check_mount(sb->s_type->name);
}

static int joe_fs_context_parse_param(struct fs_context *fc,
				      struct fs_parameter *param)
{
	int ret = joe_check_mount(fc->fs_type->name);

	/* Joe never consumes filesystem parameters itself. */
	return ret ? ret : -ENOPARAM;
}

static int joe_fsconfig(struct fs_context *fc, unsigned int cmd)
{
	/* Refuse creation before vfs_get_tree() can replay or modify anything. */
	if (cmd == FSCONFIG_CMD_CREATE || cmd == FSCONFIG_CMD_CREATE_EXCL ||
	    cmd == FSCONFIG_CMD_RECONFIGURE)
		return joe_check_mount(fc->fs_type->name);
	return 0;
}

static int joe_fsmount(struct fs_context *fc)
{
	/* Also covers inherited contexts and FSMOUNT_NAMESPACE. */
	return joe_check_mount(fc->fs_type->name);
}

static int joe_move_mount(const struct path *from_path, const struct path *to_path)
{
	return joe_check_mount("move");
}

static int joe_mount_setattr(const struct path *path)
{
	return joe_check_mount("setattr");
}

static int joe_sb_umount(struct vfsmount *mnt, int flags)
{
	return joe_check_mount("umount");
}

static int joe_sb_remount(struct super_block *sb, void *mnt_opts)
{
	return joe_check_mount("remount");
}

static int joe_sb_pivotroot(const struct path *old_path, const struct path *new_path)
{
	return joe_check_mount("pivotroot");
}

static int joe_ptrace_access_check(struct task_struct *child, unsigned int mode)
{
	const struct cred *cred = current_cred();
	struct joe_ops *ops = joe_cred(cred)->ops;

	if (!(mode & PTRACE_MODE_ATTACH) || !ops || !joe_privileged(cred) ||
	    joe_ops_allows(ops, JOE_PTRACE))
		return 0;
	return joe_flag_violation(ops, JOE_PTRACE, "ptrace", child->comm, -EPERM);
}

/*
 * A ptrace declaration permits inspection and ordinary data writes, not an
 * exception to rule 2. access_remote_vm supplies the VMA for ptrace and
 * /proc/PID/mem; process_vm_writev supplies the target task instead.
 */
static int joe_remote_write(struct task_struct *task, struct vm_area_struct *vma)
{
	const struct cred *cred = current_cred();
	struct joe_ops *ops = joe_cred(cred)->ops;

	if (!joe_privileged(cred))
		return 0;
	if (vma && !(vma->vm_flags & VM_EXEC))
		return 0;
	if (task && !joe_task_privileged(task))
		return 0;
	if (!vma && !task)
		return 0;
	return joe_violation(ops, "jit",
			     vma ? "remote-executable-write" : "process-vm-write", -EACCES);
}

static int joe_bpf(int cmd, union bpf_attr *attr, unsigned int size, bool kernel)
{
	const struct cred *cred = current_cred();
	struct joe_ops *ops = joe_cred(cred)->ops;

	if (kernel || !ops || !joe_privileged(cred) || joe_ops_allows(ops, JOE_BPF))
		return 0;
	return joe_flag_violation(ops, JOE_BPF, "bpf", "-", -EPERM);
}

/* ------------------------------------------------------------------------ */
/* Housekeeping                                                              */
/* ------------------------------------------------------------------------ */

static void joe_file_free_security(struct file *file)
{
	struct joe_file *jf = joe_file(file);

	joe_ops_put(jf->fown_ops);
	put_pid(jf->fown_tgid);
}

static int joe_cred_prepare(struct cred *new, const struct cred *old, gfp_t gfp)
{
	joe_cred(new)->ops = joe_ops_get(joe_cred(old)->ops);
	return 0;
}

static void joe_cred_transfer(struct cred *new, const struct cred *old)
{
	joe_ops_put(joe_cred(new)->ops);
	joe_cred(new)->ops = joe_ops_get(joe_cred(old)->ops);
}

static void joe_cred_free(struct cred *cred)
{
	joe_ops_put(joe_cred(cred)->ops);
	joe_cred(cred)->ops = NULL;
}

static void joe_inode_free_security_rcu(void *inode_security)
{
	struct joe_inode *blob = inode_security + joe_blob_sizes.lbs_inode;

	joe_ops_put(rcu_dereference_protected(blob->ops, true));
}

static void joe_inode_post_setxattr(struct dentry *dentry, const char *name,
				    const void *value, size_t size, int flags)
{
	if (!strcmp(name, JOE_XATTR))
		joe_forget(d_backing_inode(dentry));
}

static void joe_inode_post_removexattr(struct dentry *dentry, const char *name)
{
	if (!strcmp(name, JOE_XATTR))
		joe_forget(d_backing_inode(dentry));
}

static const struct lsm_id joe_lsmid = {
	.name = "joe",
	.id = LSM_ID_JOE,
};

static struct security_hook_list joe_hooks[] __ro_after_init = {
	LSM_HOOK_INIT(bprm_check_security, joe_bprm_check_security),
	LSM_HOOK_INIT(bprm_creds_for_exec, joe_bprm_creds_for_exec),
	LSM_HOOK_INIT(bprm_creds_from_file, joe_bprm_creds_from_file),
	LSM_HOOK_INIT(file_ioctl, joe_file_ioctl),
	LSM_HOOK_INIT(file_ioctl_compat, joe_file_ioctl),
	LSM_HOOK_INIT(mmap_file, joe_mmap_file),
	LSM_HOOK_INIT(file_mprotect, joe_file_mprotect),
	LSM_HOOK_INIT(kernel_read_file, joe_kernel_read_file),
	LSM_HOOK_INIT(kernel_load_data, joe_kernel_load_data),
	LSM_HOOK_INIT(capable, joe_capable),
	LSM_HOOK_INIT(task_kill, joe_task_kill),
	LSM_HOOK_INIT(file_set_fowner, joe_file_set_fowner),
	LSM_HOOK_INIT(file_send_sigiotask, joe_file_send_sigiotask),
	LSM_HOOK_INIT(ipc_permission, joe_ipc_permission),
	LSM_HOOK_INIT(shm_shmctl, joe_shm_shmctl),
	LSM_HOOK_INIT(msg_queue_msgctl, joe_msg_queue_msgctl),
	LSM_HOOK_INIT(sem_semctl, joe_sem_semctl),
	LSM_HOOK_INIT(userns_create, joe_userns_create),
	LSM_HOOK_INIT(socket_create, joe_socket_create),
	LSM_HOOK_INIT(file_open, joe_file_open),
	LSM_HOOK_INIT(path_unlink, joe_path_unlink),
	LSM_HOOK_INIT(path_mkdir, joe_path_mkdir),
	LSM_HOOK_INIT(path_rmdir, joe_path_rmdir),
	LSM_HOOK_INIT(path_mknod, joe_path_mknod),
	LSM_HOOK_INIT(path_symlink, joe_path_symlink),
	LSM_HOOK_INIT(path_link, joe_path_link),
	LSM_HOOK_INIT(path_rename, joe_path_rename),
	LSM_HOOK_INIT(path_truncate, joe_path_truncate),
	LSM_HOOK_INIT(sb_mount, joe_sb_mount),
	LSM_HOOK_INIT(sb_kern_mount, joe_sb_kern_mount),
	LSM_HOOK_INIT(fs_context_parse_param, joe_fs_context_parse_param),
	LSM_HOOK_INIT(fsconfig, joe_fsconfig),
	LSM_HOOK_INIT(fsmount, joe_fsmount),
	LSM_HOOK_INIT(move_mount, joe_move_mount),
	LSM_HOOK_INIT(mount_setattr, joe_mount_setattr),
	LSM_HOOK_INIT(sb_umount, joe_sb_umount),
	LSM_HOOK_INIT(sb_remount, joe_sb_remount),
	LSM_HOOK_INIT(sb_pivotroot, joe_sb_pivotroot),
	LSM_HOOK_INIT(ptrace_access_check, joe_ptrace_access_check),
	LSM_HOOK_INIT(remote_write, joe_remote_write),
	LSM_HOOK_INIT(bpf, joe_bpf),
	LSM_HOOK_INIT(file_free_security, joe_file_free_security),
	LSM_HOOK_INIT(cred_prepare, joe_cred_prepare),
	LSM_HOOK_INIT(cred_transfer, joe_cred_transfer),
	LSM_HOOK_INIT(cred_free, joe_cred_free),
	LSM_HOOK_INIT(inode_free_security_rcu, joe_inode_free_security_rcu),
	LSM_HOOK_INIT(inode_post_setxattr, joe_inode_post_setxattr),
	LSM_HOOK_INIT(inode_post_removexattr, joe_inode_post_removexattr),
};

static int __init joe_setup(char *str)
{
	if (!strcmp(str, "enforce"))
		joe_enforce = true;
	else if (!strcmp(str, "log"))
		joe_enforce = false;
	return 1;
}
__setup("joe=", joe_setup);

static int __init joe_init(void)
{
	security_add_hooks(joe_hooks, ARRAY_SIZE(joe_hooks), &joe_lsmid);
	pr_info("%s mode, %zu trusted key(s)\n", joe_enforce ? "enforcing" : "log",
		ARRAY_SIZE(joe_keys));
	return 0;
}

static ssize_t joe_enforce_read(struct file *file, char __user *buf,
				size_t count, loff_t *ppos)
{
	return simple_read_from_buffer(buf, count, ppos, joe_enforce ? "1\n" : "0\n", 2);
}

static ssize_t joe_enforce_write(struct file *file, const char __user *buf,
				 size_t count, loff_t *ppos)
{
	char c;

	if (count < 1 || get_user(c, buf))
		return -EINVAL;
	/* One way only. */
	if (c != '1')
		return -EPERM;
	if (!joe_enforce) {
		joe_enforce = true;
		pr_info("now enforcing\n");
	}
	return count;
}

static const struct file_operations joe_enforce_fops = {
	.read = joe_enforce_read,
	.write = joe_enforce_write,
	.llseek = default_llseek,
};

static int __init joe_init_securityfs(void)
{
	struct dentry *dir = securityfs_create_dir("joe", NULL);

	if (IS_ERR(dir))
		return PTR_ERR(dir);
	return PTR_ERR_OR_ZERO(securityfs_create_file("enforce", 0600, dir, NULL,
						      &joe_enforce_fops));
}

DEFINE_LSM(joe) = {
	.id = &joe_lsmid,
	.init = joe_init,
	.blobs = &joe_blob_sizes,
	.initcall_fs = joe_init_securityfs,
};
