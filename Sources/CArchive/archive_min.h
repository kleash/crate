/*-
 * The subset of the libarchive 3.7.4 public API that Crate uses.
 *
 * macOS ships libarchive 3.7.4 (/usr/lib/libarchive.2.dylib, SDK libarchive.tbd)
 * but no headers. Declarations and constant values below are copied from
 * libarchive 3.7.4 archive.h and archive_entry.h, with the portability macros
 * resolved for macOS: __LA_DECL dropped, la_int64_t/la_ssize_t typedef'd
 * directly, and __LA_MODE_T spelled mode_t (Swift does not import the AE_IF*
 * constants through a macro type). To use another libarchive function, copy
 * its 3.7.4 declaration into the matching section and check that the SDK's
 * libarchive.tbd exports it.
 *
 * Copyright (c) 2003-2010 Tim Kientzle
 * Copyright (c) 2016 Martin Matuska
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#ifndef CARCHIVE_ARCHIVE_MIN_H
#define CARCHIVE_ARCHIVE_MIN_H

#include <sys/types.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

typedef int64_t la_int64_t;
typedef ssize_t la_ssize_t;

struct archive;
struct archive_entry;

/* ---- Version ---------------------------------------------------------- */

int		archive_version_number(void);
const char *	archive_version_string(void);
const char *	archive_version_details(void);

/* ---- Status codes ----------------------------------------------------- */

#define	ARCHIVE_EOF	  1	/* Found end of archive. */
#define	ARCHIVE_OK	  0	/* Operation was successful. */
#define	ARCHIVE_RETRY	(-10)	/* Retry might succeed. */
#define	ARCHIVE_WARN	(-20)	/* Partial success. */
#define	ARCHIVE_FAILED	(-25)	/* Current operation cannot complete. */
#define	ARCHIVE_FATAL	(-30)	/* No more operations are possible. */

/* ---- Filter codes (archive_filter_code) ------------------------------- */

#define	ARCHIVE_FILTER_NONE	0
#define	ARCHIVE_FILTER_GZIP	1
#define	ARCHIVE_FILTER_BZIP2	2
#define	ARCHIVE_FILTER_COMPRESS	3
#define	ARCHIVE_FILTER_PROGRAM	4
#define	ARCHIVE_FILTER_LZMA	5
#define	ARCHIVE_FILTER_XZ	6
#define	ARCHIVE_FILTER_UU	7
#define	ARCHIVE_FILTER_RPM	8
#define	ARCHIVE_FILTER_LZIP	9
#define	ARCHIVE_FILTER_LRZIP	10
#define	ARCHIVE_FILTER_LZOP	11
#define	ARCHIVE_FILTER_GRZIP	12
#define	ARCHIVE_FILTER_LZ4	13
#define	ARCHIVE_FILTER_ZSTD	14

/* ---- Format families (archive_format() & ARCHIVE_FORMAT_BASE_MASK) ----- */

#define	ARCHIVE_FORMAT_BASE_MASK		0xff0000
#define	ARCHIVE_FORMAT_CPIO			0x10000
#define	ARCHIVE_FORMAT_SHAR			0x20000
#define	ARCHIVE_FORMAT_TAR			0x30000
#define	ARCHIVE_FORMAT_ISO9660			0x40000
#define	ARCHIVE_FORMAT_ZIP			0x50000
#define	ARCHIVE_FORMAT_EMPTY			0x60000
#define	ARCHIVE_FORMAT_AR			0x70000
#define	ARCHIVE_FORMAT_MTREE			0x80000
#define	ARCHIVE_FORMAT_RAW			0x90000
#define	ARCHIVE_FORMAT_XAR			0xA0000
#define	ARCHIVE_FORMAT_LHA			0xB0000
#define	ARCHIVE_FORMAT_CAB			0xC0000
#define	ARCHIVE_FORMAT_RAR			0xD0000
#define	ARCHIVE_FORMAT_7ZIP			0xE0000
#define	ARCHIVE_FORMAT_WARC			0xF0000
#define	ARCHIVE_FORMAT_RAR_V5			0x100000

/* ---- Encryption detection --------------------------------------------- */

/* archive_read_format_capabilities() */
#define ARCHIVE_READ_FORMAT_CAPS_NONE (0) /* no special capabilities */
#define ARCHIVE_READ_FORMAT_CAPS_ENCRYPT_DATA (1<<0)  /* reader can detect encrypted data */
#define ARCHIVE_READ_FORMAT_CAPS_ENCRYPT_METADATA (1<<1)  /* reader can detect encryptable metadata (pathname, mtime, etc.) */

/* archive_read_has_encrypted_entries() */
#define ARCHIVE_READ_FORMAT_ENCRYPTION_UNSUPPORTED -2
#define ARCHIVE_READ_FORMAT_ENCRYPTION_DONT_KNOW -1

/* ---- Client callbacks (archive_read_open2, archive_write_open) -------- */

/* Returns size actually read, zero for EOF, -1 for error. */
typedef la_ssize_t	archive_read_callback(struct archive *,
			    void *_client_data, const void **_buffer);
/* Skips at most request bytes from archive and returns the skipped amount.
 * This may skip fewer bytes than requested; it may even skip zero bytes.
 * If you do skip fewer bytes than requested, libarchive will invoke your
 * read callback and discard data as necessary to make up the full skip.
 */
typedef la_int64_t	archive_skip_callback(struct archive *,
			    void *_client_data, la_int64_t request);
/* Seeks to specified location in the file and returns the position.
 * Whence values are SEEK_SET, SEEK_CUR, SEEK_END from stdio.h.
 * Return ARCHIVE_FATAL if the seek fails for any reason.
 */
typedef la_int64_t	archive_seek_callback(struct archive *,
    void *_client_data, la_int64_t offset, int whence);
/* Returns size actually written, zero on EOF, -1 on error. */
typedef la_ssize_t	archive_write_callback(struct archive *,
			    void *_client_data,
			    const void *_buffer, size_t _length);
typedef int	archive_open_callback(struct archive *, void *_client_data);
typedef int	archive_close_callback(struct archive *, void *_client_data);

/* ---- Reading an archive ----------------------------------------------- */

struct archive	*archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_empty(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_open_filename(struct archive *,
		     const char *_filename, size_t _block_size);
/* Set before archive_read_open2(), which has no seek parameter. */
int archive_read_set_seek_callback(struct archive *,
    archive_seek_callback *);
int archive_read_open2(struct archive *, void *_client_data,
		     archive_open_callback *, archive_read_callback *,
		     archive_skip_callback *, archive_close_callback *);
int archive_read_next_header(struct archive *,
		     struct archive_entry **);
int	archive_read_has_encrypted_entries(struct archive *);
int		 archive_read_format_capabilities(struct archive *);
la_ssize_t		 archive_read_data(struct archive *,
				    void *, size_t);
int archive_read_data_block(struct archive *a,
		    const void **buff, size_t *size, la_int64_t *offset);
int archive_read_data_skip(struct archive *);
int archive_read_set_options(struct archive *_a,
			    const char *opts);
int archive_read_add_passphrase(struct archive *, const char *);
int		 archive_read_close(struct archive *);
int		 archive_read_free(struct archive *);

/* ---- Writing an archive ----------------------------------------------- */

struct archive	*archive_write_new(void);
int archive_write_add_filter_bzip2(struct archive *);
int archive_write_add_filter_gzip(struct archive *);
int archive_write_add_filter_none(struct archive *);
int archive_write_add_filter_xz(struct archive *);
int archive_write_set_format_7zip(struct archive *);
int archive_write_set_format_pax_restricted(struct archive *);
int archive_write_set_format_zip(struct archive *);
int archive_write_set_options(struct archive *_a,
			    const char *opts);
int archive_write_set_passphrase(struct archive *_a, const char *p);
int archive_write_open_filename(struct archive *, const char *_file);
int archive_write_open(struct archive *, void *,
		     archive_open_callback *, archive_write_callback *,
		     archive_close_callback *);
/* 1: no padding after the last byte (the default pads to a full 10240-byte block). */
int archive_write_set_bytes_in_last_block(struct archive *,
		     int bytes_in_last_block);
int archive_write_header(struct archive *,
		     struct archive_entry *);
la_ssize_t	archive_write_data(struct archive *,
			    const void *, size_t);
/* write_data_block is only available for archive_write_disk handles. */
la_ssize_t	 archive_write_data_block(struct archive *,
				    const void *, size_t, la_int64_t);
int		 archive_write_finish_entry(struct archive *);
int		 archive_write_close(struct archive *);
/* Marks the archive FATAL so a following free() does not close() cleanly. */
int            archive_write_fail(struct archive *);
int		 archive_write_free(struct archive *);

/* ---- Writing to disk (extraction) ------------------------------------- */

struct archive	*archive_write_disk_new(void);
int		 archive_write_disk_set_options(struct archive *,
		     int flags);

/* Flags for archive_write_disk_set_options(). */
#define	ARCHIVE_EXTRACT_OWNER			(0x0001)
#define	ARCHIVE_EXTRACT_PERM			(0x0002)
#define	ARCHIVE_EXTRACT_TIME			(0x0004)
#define	ARCHIVE_EXTRACT_NO_OVERWRITE 		(0x0008)
#define	ARCHIVE_EXTRACT_UNLINK			(0x0010)
#define	ARCHIVE_EXTRACT_ACL			(0x0020)
#define	ARCHIVE_EXTRACT_FFLAGS			(0x0040)
#define	ARCHIVE_EXTRACT_XATTR 			(0x0080)
#define	ARCHIVE_EXTRACT_SECURE_SYMLINKS		(0x0100)
#define	ARCHIVE_EXTRACT_SECURE_NODOTDOT		(0x0200)
#define	ARCHIVE_EXTRACT_NO_AUTODIR		(0x0400)
#define	ARCHIVE_EXTRACT_NO_OVERWRITE_NEWER	(0x0800)
#define	ARCHIVE_EXTRACT_SPARSE			(0x1000)
#define	ARCHIVE_EXTRACT_MAC_METADATA		(0x2000)
#define	ARCHIVE_EXTRACT_NO_HFS_COMPRESSION	(0x4000)
#define	ARCHIVE_EXTRACT_HFS_COMPRESSION_FORCED	(0x8000)
#define ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS (0x10000)
#define	ARCHIVE_EXTRACT_CLEAR_NOCHANGE_FFLAGS	(0x20000)
#define	ARCHIVE_EXTRACT_SAFE_WRITES		(0x40000)

/* ---- Reading from disk (archive creation) ----------------------------- */

struct archive *archive_read_disk_new(void);
int	archive_read_disk_set_standard_lookup(struct archive *);
int	archive_read_disk_open(struct archive *, const char *);
int	archive_read_disk_descend(struct archive *);
int  archive_read_disk_set_behavior(struct archive *,
		    int flags);

/* Flags for archive_read_disk_set_behavior(). */
#define	ARCHIVE_READDISK_RESTORE_ATIME		(0x0001)
#define	ARCHIVE_READDISK_HONOR_NODUMP		(0x0002)
#define	ARCHIVE_READDISK_MAC_COPYFILE		(0x0004)
#define	ARCHIVE_READDISK_NO_TRAVERSE_MOUNTS	(0x0008)
#define	ARCHIVE_READDISK_NO_XATTR		(0x0010)
#define	ARCHIVE_READDISK_NO_ACL			(0x0020)
#define	ARCHIVE_READDISK_NO_FFLAGS		(0x0040)
#define	ARCHIVE_READDISK_NO_SPARSE		(0x0080)

/* ---- Archive object accessors ----------------------------------------- */

/* Filter #0 is closest to the format; -1 is the raw file (compressed bytes). */
int		 archive_filter_count(struct archive *);
la_int64_t	 archive_filter_bytes(struct archive *, int);
int		 archive_filter_code(struct archive *, int);
const char *	 archive_filter_name(struct archive *, int);

int		 archive_errno(struct archive *);
const char	*archive_error_string(struct archive *);
const char	*archive_format_name(struct archive *);
int		 archive_format(struct archive *);

/* ---- archive_entry ---------------------------------------------------- */

/* File types: archive_entry_filetype() / archive_entry_set_filetype(). */
#define AE_IFMT		((mode_t)0170000)
#define AE_IFREG	((mode_t)0100000)
#define AE_IFLNK	((mode_t)0120000)
#define AE_IFSOCK	((mode_t)0140000)
#define AE_IFCHR	((mode_t)0020000)
#define AE_IFBLK	((mode_t)0060000)
#define AE_IFDIR	((mode_t)0040000)
#define AE_IFIFO	((mode_t)0010000)

struct archive_entry	*archive_entry_clear(struct archive_entry *);
struct archive_entry	*archive_entry_clone(struct archive_entry *);
void			 archive_entry_free(struct archive_entry *);
struct archive_entry	*archive_entry_new(void);

/* Getters. The _utf8 forms do not depend on the process locale. */
mode_t	 archive_entry_filetype(struct archive_entry *);
const char	*archive_entry_hardlink(struct archive_entry *);
const char	*archive_entry_hardlink_utf8(struct archive_entry *);
mode_t	 archive_entry_mode(struct archive_entry *);
time_t	 archive_entry_mtime(struct archive_entry *);
long		 archive_entry_mtime_nsec(struct archive_entry *);
int		 archive_entry_mtime_is_set(struct archive_entry *);
const char	*archive_entry_pathname(struct archive_entry *);
const char	*archive_entry_pathname_utf8(struct archive_entry *);
mode_t	 archive_entry_perm(struct archive_entry *);
const char	*archive_entry_sourcepath(struct archive_entry *);
la_int64_t	 archive_entry_size(struct archive_entry *);
int		 archive_entry_size_is_set(struct archive_entry *);
const char	*archive_entry_symlink(struct archive_entry *);
const char	*archive_entry_symlink_utf8(struct archive_entry *);
int archive_entry_is_data_encrypted(struct archive_entry *);
int archive_entry_is_metadata_encrypted(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);

/* Setters. All of them copy the string they are given. */
void	archive_entry_set_filetype(struct archive_entry *, unsigned int);
void	archive_entry_set_hardlink(struct archive_entry *, const char *);
void	archive_entry_set_hardlink_utf8(struct archive_entry *, const char *);
int	archive_entry_update_hardlink_utf8(struct archive_entry *, const char *);
void	archive_entry_set_mode(struct archive_entry *, mode_t);
void	archive_entry_set_mtime(struct archive_entry *, time_t, long);
void	archive_entry_set_pathname(struct archive_entry *, const char *);
void	archive_entry_set_pathname_utf8(struct archive_entry *, const char *);
int	archive_entry_update_pathname_utf8(struct archive_entry *, const char *);
void	archive_entry_set_perm(struct archive_entry *, mode_t);
void	archive_entry_set_size(struct archive_entry *, la_int64_t);
void	archive_entry_unset_size(struct archive_entry *);
void	archive_entry_set_symlink(struct archive_entry *, const char *);
void	archive_entry_set_symlink_utf8(struct archive_entry *, const char *);
int	archive_entry_update_symlink_utf8(struct archive_entry *, const char *);

#endif /* !CARCHIVE_ARCHIVE_MIN_H */
