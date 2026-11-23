/*
 * generate-memos.c: writes MemoDB.pdb (Memo Pad, Palm OS before 5.2) and
 * MemosDB-PMem.pdb (Memos, Palm OS 5.2 and later), the golden fixtures for
 * the Swift memo codec, with pilot-link's own pack_Memo and
 * pack_MemoAppInfo. Both applications write the same record (the text,
 * NUL-terminated) and the same AppInfo block; only name and creator differ.
 *
 * Every record kind the codec has to round-trip byte for byte: a one-line
 * memo, several lines, blank lines, Windows-1252 text, an empty memo, a
 * private one, a deleted one, one of exactly 4096 bytes (Memo Pad's
 * limit) and, in MemosDB-PMem only, one of 20 KB.
 *
 * Build against the libpisock that Scripts/build-pilot-link.sh installs:
 *
 *   P=.build/pilot-link/install
 *   clang -I$P/include -L$P/lib -lpisock -o /tmp/gen Tests/PalmSyncTests/Fixtures/generate-memos.c
 *   DYLD_LIBRARY_PATH=$P/lib /tmp/gen Tests/PalmSyncTests/Fixtures
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pi-dlp.h"
#include "pi-file.h"
#include "pi-memo.h"

#define FOURCC(a, b, c, d) \
	(((unsigned long)(a) << 24) | ((unsigned long)(b) << 16) | ((unsigned long)(c) << 8) | (unsigned long)(d))

static pi_file_t *create(const char *dir, const char *name, const char *creator)
{
	struct DBInfo info;
	char path[1024];
	pi_file_t *pf;

	memset(&info, 0, sizeof(info));
	strcpy(info.name, name);
	info.flags = dlpDBFlagBackup;
	info.version = 0;
	info.type = FOURCC('D', 'A', 'T', 'A');
	info.creator = FOURCC(creator[0], creator[1], creator[2], creator[3]);
	info.createDate = info.modifyDate = 1795305600;	/* 2026-11-22T00:00:00Z */
	snprintf(path, sizeof(path), "%s/%s.pdb", dir, name);
	pf = pi_file_create(path, &info);
	if (pf == NULL) {
		fprintf(stderr, "cannot create %s\n", path);
		exit(1);
	}
	return pf;
}

static void add(pi_file_t *pf, const char *text, int attrs, int category, unsigned long uid)
{
	pi_buffer_t *buf = pi_buffer_new(256);
	Memo_t m;

	m.text = (char *)text;
	if (pack_Memo(&m, buf, memo_v1) < 0) {
		fprintf(stderr, "pack_Memo failed\n");
		exit(1);
	}
	if (pi_file_append_record(pf, buf->data, buf->used, attrs, category, uid) < 0) {
		fprintf(stderr, "pi_file_append_record failed\n");
		exit(1);
	}
	pi_buffer_free(buf);
}

/* `bytes` bytes of text: numbered lines of 16 bytes each, cut to size */
static char *filler(size_t bytes)
{
	char *text = malloc(bytes + 1);
	size_t i;

	for (i = 0; i < bytes; i++) {
		if (i % 16 == 15)
			text[i] = '\n';
		else
			text[i] = "0123456789abcdef"[(i / 16) % 16];
	}
	text[bytes] = 0;
	return text;
}

static void memos(const char *dir, const char *name, const char *creator, int garnet)
{
	pi_file_t *pf = create(dir, name, creator);
	MemoAppInfo_t ai;
	unsigned char info[300];
	char *big;
	int n, i;

	memset(&ai, 0, sizeof(ai));
	ai.type = memo_v1;
	strcpy(ai.category.name[0], "Unfiled");
	strcpy(ai.category.name[1], "Business");
	strcpy(ai.category.name[2], "Personal");
	strcpy(ai.category.name[3], "Recipes");
	for (i = 0; i < 16; i++)
		ai.category.ID[i] = (unsigned char)i;
	ai.category.lastUniqueID = 15;
	ai.sortByAlpha = 1;
	n = pack_MemoAppInfo(&ai, info, sizeof(info));
	pi_file_set_app_info(pf, info, (size_t)n);

	/* 0: one line */
	add(pf, "Shopping", 0, 2, 0x4001);
	/* 1: title, blank line, two lines; Windows-1252 */
	add(pf, "Caf\xe9 list\n\nCr\xe8me br\xfbl\xe9" "e \x96 2 \x80\nStra\xdf" "e 7", 0, 3, 0x4002);
	/* 2: empty memo, dirty */
	add(pf, "", dlpRecAttrDirty, 0, 0x4003);
	/* 3: private */
	add(pf, "PIN 1234\nnot for everyone", dlpRecAttrSecret, 1, 0x4004);
	/* 4: deleted */
	add(pf, "Gone", dlpRecAttrDeleted, 0, 0x4005);
	/* 5: exactly 4096 bytes of text, Memo Pad's limit */
	big = filler(4096);
	add(pf, big, 0, 0, 0x4006);
	free(big);
	/* 6: trailing newline kept as it is */
	add(pf, "Ends with a newline\n", 0, 2, 0x4007);
	if (garnet) {
		/* 7: 20 KB, more than Memo Pad holds */
		big = filler(20480);
		add(pf, big, 0, 1, 0x4008);
		free(big);
	}

	pi_file_close(pf);
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s <Fixtures directory>\n", argv[0]);
		return 2;
	}
	memos(argv[1], "MemoDB", "memo", 0);
	memos(argv[1], "MemosDB-PMem", "PMem", 1);
	return 0;
}
