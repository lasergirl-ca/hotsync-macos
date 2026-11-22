/*
 * generate-classic.c: writes DatebookDB.pdb, AddressDB.pdb and ToDoDB.pdb,
 * the golden fixtures for the Swift codecs of the classic PIM databases
 * (Palm OS before 5.2: Datebook, Address, To Do), with pilot-link's own
 * pack_Appointment, pack_Address and pack_ToDo and their AppInfo packers.
 *
 * Every record kind the codecs have to round-trip byte for byte: timed and
 * timeless appointments, alarms, every repeat type, exceptions, notes;
 * addresses with every field, five phones with labels, a shown phone,
 * Windows-1252 text; to-dos with and without due date, completed, every
 * priority, empty and full notes.
 *
 * Build against the libpisock that Scripts/build-pilot-link.sh installs:
 *
 *   P=.build/pilot-link/install
 *   clang -I$P/include -L$P/lib -lpisock -o /tmp/gen Tests/PalmSyncTests/Fixtures/generate-classic.c
 *   DYLD_LIBRARY_PATH=$P/lib /tmp/gen Tests/PalmSyncTests/Fixtures
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "pi-address.h"
#include "pi-datebook.h"
#include "pi-dlp.h"
#include "pi-file.h"
#include "pi-todo.h"

#define FOURCC(a, b, c, d) \
	(((unsigned long)(a) << 24) | ((unsigned long)(b) << 16) | ((unsigned long)(c) << 8) | (unsigned long)(d))

static void date(struct tm *t, int year, int month, int day, int hour, int min)
{
	memset(t, 0, sizeof(*t));
	t->tm_year = year - 1900;
	t->tm_mon = month - 1;
	t->tm_mday = day;
	t->tm_hour = hour;
	t->tm_min = min;
	t->tm_isdst = -1;
}

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
	info.createDate = info.modifyDate = 1792368000;	/* 2026-10-19T00:00:00Z */
	snprintf(path, sizeof(path), "%s/%s.pdb", dir, name);
	pf = pi_file_create(path, &info);
	if (pf == NULL) {
		fprintf(stderr, "cannot create %s\n", path);
		exit(1);
	}
	return pf;
}

static void categories(struct CategoryAppInfo *c, const char *a, const char *b, const char *d)
{
	int i;

	memset(c, 0, sizeof(*c));
	strcpy(c->name[0], "Unfiled");
	strcpy(c->name[1], a);
	strcpy(c->name[2], b);
	strcpy(c->name[3], d);
	for (i = 0; i < 16; i++)
		c->ID[i] = (unsigned char)i;
	c->lastUniqueID = 3;
}

static void add(pi_file_t *pf, pi_buffer_t *buf, int attrs, int category, unsigned long uid)
{
	if (pi_file_append_record(pf, buf->data, buf->used, attrs, category, uid) < 0) {
		fprintf(stderr, "pi_file_append_record failed\n");
		exit(1);
	}
}

/* ---- Datebook ----------------------------------------------------------- */

static void datebook(const char *dir)
{
	pi_file_t *pf = create(dir, "DatebookDB", "date");
	AppointmentAppInfo_t ai;
	unsigned char info[300];
	Appointment_t a;
	pi_buffer_t *buf = pi_buffer_new(256);
	int n;

	memset(&ai, 0, sizeof(ai));
	categories(&ai.category, "Work", "Family", "G Work");
	ai.startOfWeek = 0;
	n = pack_AppointmentAppInfo(&ai, info, sizeof(info));
	pi_file_set_app_info(pf, info, (size_t)n);

#define APPT_RESET() do { memset(&a, 0, sizeof(a)); a.repeatForever = 1; } while (0)
#define APPT(attrs, cat, uid) do { buf->used = 0; \
	if (pack_Appointment(&a, buf, datebook_v1) < 0) { fprintf(stderr, "pack_Appointment failed\n"); exit(1); } \
	add(pf, buf, attrs, cat, uid); } while (0)

	/* 0: plain timed event */
	APPT_RESET();
	date(&a.begin, 2026, 10, 20, 9, 0);
	date(&a.end, 2026, 10, 20, 10, 0);
	a.description = "Standup";
	APPT(0, 1, 0x1001);
	/* 1: timeless with a note */
	APPT_RESET();
	a.event = 1;
	date(&a.begin, 2026, 11, 1, 0, 0);
	a.end = a.begin;
	a.description = "Clocks stay";
	a.note = "No fall back in BC";
	APPT(0, 0, 0x1002);
	/* 2: alarm 15 minutes before */
	APPT_RESET();
	date(&a.begin, 2026, 10, 21, 14, 30);
	date(&a.end, 2026, 10, 21, 15, 0);
	a.alarm = 1;
	a.advance = 15;
	a.advanceUnits = advMinutes;
	a.description = "Dentist";
	APPT(0, 2, 0x1003);
	/* 3: daily forever */
	APPT_RESET();
	date(&a.begin, 2026, 10, 1, 8, 0);
	date(&a.end, 2026, 10, 1, 8, 15);
	a.repeatType = repeatDaily;
	a.repeatFrequency = 1;
	a.description = "Meds";
	APPT(0, 0, 0x1004);
	/* 4: weekly Mon/Wed/Fri until 2027-03-31, two exceptions */
	APPT_RESET();
	date(&a.begin, 2026, 10, 19, 18, 0);
	date(&a.end, 2026, 10, 19, 19, 0);
	a.repeatType = repeatWeekly;
	a.repeatForever = 0;
	date(&a.repeatEnd, 2027, 3, 31, 0, 0);
	a.repeatFrequency = 1;
	a.repeatDays[1] = a.repeatDays[3] = a.repeatDays[5] = 1;
	a.repeatWeekstart = 0;
	a.exceptions = 2;
	a.exception = calloc(2, sizeof(struct tm));
	date(&a.exception[0], 2026, 10, 23, 0, 0);
	date(&a.exception[1], 2026, 10, 28, 0, 0);
	a.description = "Gym";
	APPT(0, 2, 0x1005);
	free(a.exception);
	/* 5: monthly by day, second Tuesday, forever */
	APPT_RESET();
	date(&a.begin, 2026, 10, 13, 19, 0);
	date(&a.end, 2026, 10, 13, 21, 0);
	a.repeatType = repeatMonthlyByDay;
	a.repeatFrequency = 1;
	a.repeatDay = dom2ndTue;
	a.description = "Book club";
	APPT(0, 3, 0x1006);
	/* 6: monthly by date, every 2 months, until 2027-12-31 */
	APPT_RESET();
	date(&a.begin, 2026, 10, 15, 12, 0);
	date(&a.end, 2026, 10, 15, 13, 0);
	a.repeatType = repeatMonthlyByDate;
	a.repeatForever = 0;
	date(&a.repeatEnd, 2027, 12, 31, 0, 0);
	a.repeatFrequency = 2;
	a.description = "Invoice";
	APPT(0, 1, 0x1007);
	/* 7: yearly, timeless, alarm 1 day before, dirty */
	APPT_RESET();
	a.event = 1;
	date(&a.begin, 2026, 12, 24, 0, 0);
	a.end = a.begin;
	a.repeatType = repeatYearly;
	a.repeatFrequency = 1;
	a.alarm = 1;
	a.advance = 1;
	a.advanceUnits = advDays;
	a.description = "Mom\xe2s birthday";	/* Windows-1252 â */
	a.note = "Caf\xe9";
	APPT(dlpRecAttrDirty, 2, 0x1008);
	/* 8: deleted record */
	APPT_RESET();
	date(&a.begin, 2026, 10, 2, 7, 0);
	date(&a.end, 2026, 10, 2, 7, 30);
	a.description = "Gone";
	APPT(dlpRecAttrDeleted, 0, 0x1009);

	pi_buffer_free(buf);
	pi_file_close(pf);
}

/* ---- Address ------------------------------------------------------------ */

static void address(const char *dir)
{
	pi_file_t *pf = create(dir, "AddressDB", "addr");
	AddressAppInfo_t ai;
	unsigned char info[700];
	Address_t ad;
	pi_buffer_t *buf = pi_buffer_new(512);
	int n, i;
	static const char *labels[22] = {
		"Last name", "First name", "Company", "Work", "Home", "Fax", "Other", "E-mail",
		"Address", "City", "State", "Zip Code", "Country", "Title",
		"Custom 1", "Custom 2", "Custom 3", "Custom 4", "Note", "Main", "Pager", "Mobile"
	};

	memset(&ai, 0, sizeof(ai));
	ai.type = address_v1;
	categories(&ai.category, "Friends", "Work", "Family");
	for (i = 0; i < 22; i++)
		strcpy(ai.labels[i], labels[i]);
	ai.country = 4;	/* Canada */
	ai.sortByCompany = 0;
	n = pack_AddressAppInfo(&ai, info, sizeof(info));
	pi_file_set_app_info(pf, info, (size_t)n);

#define ADDR_RESET() do { memset(&ad, 0, sizeof(ad)); ad.phoneLabel[0] = 0; ad.phoneLabel[1] = 1; \
	ad.phoneLabel[2] = 2; ad.phoneLabel[3] = 3; ad.phoneLabel[4] = 4; } while (0)
#define ADDR(attrs, cat, uid) do { buf->used = 0; \
	if (pack_Address(&ad, buf, address_v1) < 0) { fprintf(stderr, "pack_Address failed\n"); exit(1); } \
	add(pf, buf, attrs, cat, uid); } while (0)

	/* 0: every field, five phones, mobile shown */
	ADDR_RESET();
	ad.entry[entryLastname] = "Leto";
	ad.entry[entryFirstname] = "Zo\xeb";	/* Windows-1252 ë */
	ad.entry[entryCompany] = "Packetloq";
	ad.entry[entryPhone1] = "+1 604 555 0100";
	ad.entry[entryPhone2] = "+1 604 555 0101";
	ad.entry[entryPhone3] = "zoe@example.com";
	ad.entry[entryPhone4] = "+1 604 555 0102";
	ad.entry[entryPhone5] = "+1 604 555 0103";
	ad.phoneLabel[0] = 0;	/* work */
	ad.phoneLabel[1] = 1;	/* home */
	ad.phoneLabel[2] = 4;	/* e-mail */
	ad.phoneLabel[3] = 7;	/* mobile */
	ad.phoneLabel[4] = 2;	/* fax */
	ad.showPhone = 3;
	ad.entry[entryAddress] = "123 Main St";
	ad.entry[entryCity] = "Vancouver";
	ad.entry[entryState] = "BC";
	ad.entry[entryZip] = "V6B 1A1";
	ad.entry[entryCountry] = "Canada";
	ad.entry[entryTitle] = "Engineer";
	ad.entry[entryCustom1] = "c1";
	ad.entry[entryCustom2] = "c2";
	ad.entry[entryCustom3] = "c3";
	ad.entry[entryCustom4] = "c4";
	ad.entry[entryNote] = "Likes Palms";
	ADDR(0, 1, 0x2001);
	/* 1: company only, one phone */
	ADDR_RESET();
	ad.entry[entryCompany] = "Dentist";
	ad.entry[entryPhone1] = "+1 604 555 0200";
	ADDR(0, 0, 0x2002);
	/* 2: a name and a note, no phones, secret */
	ADDR_RESET();
	ad.entry[entryLastname] = "Smith";
	ad.entry[entryFirstname] = "Pat";
	ad.entry[entryNote] = "Line one\nLine two";
	ADDR(dlpRecAttrSecret, 2, 0x2003);
	/* 3: deleted */
	ADDR_RESET();
	ad.entry[entryLastname] = "Gone";
	ADDR(dlpRecAttrDeleted, 0, 0x2004);

	pi_buffer_free(buf);
	pi_file_close(pf);
}

/* ---- To Do -------------------------------------------------------------- */

static void todo(const char *dir)
{
	pi_file_t *pf = create(dir, "ToDoDB", "todo");
	ToDoAppInfo_t ai;
	unsigned char info[300];
	ToDo_t t;
	pi_buffer_t *buf = pi_buffer_new(256);
	int n;

	memset(&ai, 0, sizeof(ai));
	ai.type = todo_v1;
	categories(&ai.category, "Personal", "Groceries", "Amazon");
	ai.sortByPriority = 1;
	n = pack_ToDoAppInfo(&ai, info, sizeof(info));
	pi_file_set_app_info(pf, info, (size_t)n);

#define TODO_RESET() do { memset(&t, 0, sizeof(t)); t.indefinite = 1; t.priority = 1; } while (0)
#define TODO(attrs, cat, uid) do { buf->used = 0; \
	if (pack_ToDo(&t, buf, todo_v1) < 0) { fprintf(stderr, "pack_ToDo failed\n"); exit(1); } \
	add(pf, buf, attrs, cat, uid); } while (0)

	/* 0: due date, priority 2, open, note */
	TODO_RESET();
	t.indefinite = 0;
	date(&t.due, 2026, 10, 25, 0, 0);
	t.priority = 2;
	t.description = "Buy milk";
	t.note = "2%";
	TODO(0, 2, 0x3001);
	/* 1: no due date, priority 5, completed, no note */
	TODO_RESET();
	t.priority = 5;
	t.complete = 1;
	t.description = "Call mom";
	TODO(0, 1, 0x3002);
	/* 2: due date, completed, priority 1 */
	TODO_RESET();
	t.indefinite = 0;
	date(&t.due, 2026, 9, 1, 0, 0);
	t.priority = 1;
	t.complete = 1;
	t.description = "Renew insurance";
	t.note = "Done early";
	TODO(dlpRecAttrDirty, 1, 0x3003);
	/* 3: priority 3, Windows-1252 */
	TODO_RESET();
	t.priority = 3;
	t.description = "R\xe9sum\xe9";
	TODO(0, 0, 0x3004);
	/* 4: deleted */
	TODO_RESET();
	t.description = "Gone";
	TODO(dlpRecAttrDeleted, 0, 0x3005);

	pi_buffer_free(buf);
	pi_file_close(pf);
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s <Fixtures directory>\n", argv[0]);
		return 2;
	}
	datebook(argv[1]);
	address(argv[1]);
	todo(argv[1]);
	return 0;
}
