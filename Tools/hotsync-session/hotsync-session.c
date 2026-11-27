/*
 * hotsync-session: eine HotSync-Sitzung an genau einem Anschluss.
 *
 * Wozu: pilot-xfer bekommt die zu installierenden Dateien schon beim Start
 * und kann nicht erst fragen, WELCHER Palm sich gemeldet hat. HotSync
 * ordnet Dateien aber dem Palm zu (Profil = Benutzername + User-ID). Dieses
 * Werkzeug nimmt die Verbindung an, meldet die Identität des Palms und
 * wartet dann auf Anweisungen der App - so landet nie eine Datei auf dem
 * falschen Palm, auch wenn an einer Kette mehrere Palms hängen.
 *
 * Aufruf:   hotsync-session --port usb: [--timeout SEK]
 *           hotsync-session --port /dev/cu.usbserial-A1 [--timeout SEK]
 *           (Baudrate seriell über PILOTRATE, wie bei pilot-link üblich)
 *
 * stdout:   ein JSON-Objekt pro Zeile (Ereignisse, siehe emit_*)
 * stdin:    eine Anweisung pro Zeile, erst nach "connected" - solange keine
 *           kommt (z. B. während die App fragt, ob ein neuer Palm angelegt
 *           werden soll), hält das Werkzeug die Verbindung zum Palm offen:
 *             install <Pfad>   Datei installieren
 *             setuser <ID> <Name>  Palm ohne Benutzer übernimmt ein Profil
 *             log <Text>       Eintrag ins HotSync-Log des Palms
 *             backup <Ordner>  die Datenbanken im RAM nach <Ordner> sichern
 *                              (nur die seit der letzten Sicherung geänderten)
 *             getrom <Ordner>  das ROM nach <Ordner>/PalmOS-<Version>.rom
 *                              auslesen (nur Palm OS 1-4)
 *           Datensätze einer Datenbank (für den PIM-Abgleich, immer genau
 *           eine Datenbank offen; Daten als Base64, Attribute wie dlpRecAttr*):
 *             opendb <r|rw> <Name>   Datenbank öffnen (geheime Datensätze inklusive)
 *             closedb                 wieder schließen
 *             readappinfo             AppInfo-Block lesen
 *             writeappinfo <Base64>   AppInfo-Block schreiben
 *             readall                 alle Datensätze lesen (langsamer Abgleich)
 *             readmodified            nur die seit dem letzten Abgleich geänderten
 *             readrec <ID>            einen Datensatz lesen
 *             writerec <ID> <Attr> <Kategorie> <Base64>
 *                                     schreiben (ID 0: der Palm vergibt eine)
 *             deleterec <ID>          löschen
 *             resetflags              Änderungsmarken löschen (nach dem Abgleich)
 *             cleanup                 gelöschte Datensätze endgültig entfernen
 *             syncinfo <PC-ID>        lastSyncPC und Abgleichzeit im Palm setzen
 *             settime                 die Uhr des Palms auf die des Macs stellen
 *             end              Sitzung sauber beenden
 *           Relay (see "Relay" below): relay HOST[:PORT] hands the session to
 *           a network HotSync server; relaykey, relaytls and relaypair before
 *           it let the Mac answer Cradle's authenticator for the Palm.
 *
 * Exit:     0 Sitzung beendet, 1 Fehler, 2 kein Palm innerhalb des Timeouts
 */

#include <errno.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <utime.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/socket.h>
#include <dispatch/dispatch.h>
#include <CommonCrypto/CommonDigest.h>
#include <Network/Network.h>
#include <Security/Security.h>

#include "pi-dlp.h"
#include "pi-file.h"
#include "pi-socket.h"
#include "pi-source.h"
#include "pi-net.h"
#include "pi-syspkt.h"

#include "monocypher/monocypher.h"
#include "monocypher/monocypher-ed25519.h"

/* libpisock exports it (pi_bind() and pi_accept() call it) but no header
 * declares it: builds the protocol stack of a socket whose descriptor was
 * set by hand, as pi_socket_setsd() needs */
extern int pi_socket_init(pi_socket_t *ps);

/* ---- JSON-Ausgabe -------------------------------------------------------- */

/* Palm OS speichert Text in Windows-1252; für JSON brauchen wir UTF-8.
 * 0x80-0x9F weichen von Latin-1 ab, diese Tabelle deckt sie ab. */
static const unsigned short cp1252_high[32] = {
	0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
	0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
	0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
	0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178
};

static void put_utf8(unsigned int cp)
{
	if (cp < 0x80) {
		putchar((int)cp);
	} else if (cp < 0x800) {
		putchar(0xC0 | (cp >> 6));
		putchar(0x80 | (cp & 0x3F));
	} else {
		putchar(0xE0 | (cp >> 12));
		putchar(0x80 | ((cp >> 6) & 0x3F));
		putchar(0x80 | (cp & 0x3F));
	}
}

/* Schreibt einen JSON-String. palm_text: Quelle ist Windows-1252 (vom
 * Palm), sonst UTF-8 (Pfade, Meldungen) und wird nur maskiert. */
static void put_json_string(const char *s, int palm_text)
{
	const unsigned char *p = (const unsigned char *)s;

	putchar('"');
	for (; *p; p++) {
		unsigned int c = *p;
		if (c == '"' || c == '\\') {
			putchar('\\');
			putchar((int)c);
		} else if (c < 0x20) {
			printf("\\u%04x", c);
		} else if (c >= 0x80 && palm_text) {
			put_utf8(c < 0xA0 ? cp1252_high[c - 0x80] : c);
		} else {
			putchar((int)c);
		}
	}
	putchar('"');
}

/* Alle Ereignisse gehen sofort raus: die App reagiert auf jede Zeile. */
static void emit_end(void)
{
	fputs("}\n", stdout);
	fflush(stdout);
}

static void emit_begin(const char *event)
{
	fputs("{\"event\":", stdout);
	put_json_string(event, 0);
}

static void emit_str(const char *key, const char *value, int palm_text)
{
	printf(",\"%s\":", key);
	put_json_string(value, palm_text);
}

static void emit_int(const char *key, long value)
{
	printf(",\"%s\":%ld", key, value);
}

static void emit_error(const char *stage, const char *fmt, ...)
{
	char message[256];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(message, sizeof(message), fmt, ap);
	va_end(ap);

	emit_begin("error");
	emit_str("stage", stage, 0);
	emit_str("message", message, 0);
	emit_end();
}

/* Gegenrichtung für "setuser": UTF-8 von der App nach Windows-1252 für den
 * Palm. Zeichen, die es dort nicht gibt, werden zu '?'. */
static void utf8_to_cp1252(const char *in, char *out, size_t out_size)
{
	const unsigned char *p = (const unsigned char *)in;
	size_t n = 0;

	while (*p && n + 1 < out_size) {
		unsigned int cp;
		int i;

		if (*p < 0x80) {
			cp = *p++;
		} else if ((*p & 0xE0) == 0xC0 && p[1]) {
			cp = ((p[0] & 0x1F) << 6) | (p[1] & 0x3F);
			p += 2;
		} else if ((*p & 0xF0) == 0xE0 && p[1] && p[2]) {
			cp = ((p[0] & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F);
			p += 3;
		} else {
			/* 4-Byte-Folgen (Emoji) und kaputte Bytes überspringen */
			p++;
			while ((*p & 0xC0) == 0x80)
				p++;
			out[n++] = '?';
			continue;
		}

		if (cp < 0x80 || (cp >= 0xA0 && cp <= 0xFF)) {
			out[n++] = (char)cp;
			continue;
		}
		for (i = 0; i < 32; i++) {
			if (cp1252_high[i] == cp && cp != 0xFFFD)
				break;
		}
		out[n++] = i < 32 ? (char)(0x80 + i) : '?';
	}
	out[n] = '\0';
}

/* ---- Installation ------------------------------------------------------- */

static const char *base_name(const char *path)
{
	const char *slash = strrchr(path, '/');
	return slash ? slash + 1 : path;
}

/* Fortschritt je übertragenem Datensatz - die App zeigt damit, dass die
 * Übertragung lebt, und kann einen Hänger von einer großen Datei
 * unterscheiden. */
static int install_progress(int sd, pi_progress_t *progress)
{
	(void)sd;
	emit_begin("progress");
	emit_int("bytes", (long)progress->transferred_bytes);
	emit_end();
	return PI_TRANSFER_CONTINUE;
}

/* Installiert eine Datei und meldet "installed" oder "failed". Die Gründe
 * kommen als Rohcodes; die Zuordnung zu Texten macht die App (HotSyncCore),
 * damit es dafür genau eine Stelle gibt. */
static void install_file(int sd, const char *path)
{
	const char *name = base_name(path);
	struct stat sbuf;
	struct CardInfo card;
	unsigned long ram_free = 0;
	pi_file_t *pf;

	emit_begin("installing");
	emit_str("file", name, 0);
	emit_end();

	if (stat(path, &sbuf) != 0 || (pf = pi_file_open(path)) == NULL) {
		emit_begin("failed");
		emit_str("file", name, 0);
		emit_str("reason", "unreadableFile", 0);
		emit_end();
		return;
	}

	/* Freien Speicher aller Karten summieren wie pilot-xfer: lieber vorher
	 * ablehnen als mitten in der Übertragung abbrechen. */
	card.card = -1;
	card.more = 1;
	while (card.more) {
		if (dlp_ReadStorageInfo(sd, card.card + 1, &card) < 0)
			break;
		ram_free += card.ramFree;
	}
	if (ram_free > 0 && (unsigned long)sbuf.st_size > ram_free) {
		emit_begin("failed");
		emit_str("file", name, 0);
		emit_str("reason", "notEnoughSpace", 0);
		emit_int("needed", (long)sbuf.st_size);
		emit_int("available", (long)ram_free);
		emit_end();
		pi_file_close(pf);
		return;
	}

	if (pi_file_install(pf, sd, 0, install_progress) < 0) {
		emit_begin("failed");
		emit_str("file", name, 0);
		emit_str("reason", "palmError", 0);
		emit_int("error", pi_error(sd));
		emit_int("palmOSError", pi_palmos_error(sd));
		emit_end();
	} else {
		emit_begin("installed");
		emit_str("file", name, 0);
		emit_int("bytes", (long)sbuf.st_size);
		emit_end();
	}
	pi_file_close(pf);
}

/* ---- Sicherung ---------------------------------------------------------- */

/* Dateiname aus dem Datenbanknamen: '/' und Steuerzeichen gehen in keinen
 * Dateinamen, '=' maskiert (wie pilot-xfer: "=2F" für '/'). Palm-Text ist
 * Windows-1252, der Dateiname UTF-8 wie in der JSON-Ausgabe. */
static void file_name_for(char *out, size_t size, const struct DBInfo *info)
{
	const unsigned char *p = (const unsigned char *)info->name;
	size_t n = 0;

	for (; *p && n + 8 < size; p++) {
		unsigned int c = *p;

		if (c == '/' || c == '=' || c < 0x20 || c == 0x7F) {
			n += snprintf(out + n, size - n, "=%02X", c);
		} else if (c >= 0x80) {
			unsigned int cp = c < 0xA0 ? cp1252_high[c - 0x80] : c;

			if (cp < 0x800) {
				out[n++] = (char)(0xC0 | (cp >> 6));
				out[n++] = (char)(0x80 | (cp & 0x3F));
			} else {
				out[n++] = (char)(0xE0 | (cp >> 12));
				out[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
				out[n++] = (char)(0x80 | (cp & 0x3F));
			}
		} else {
			out[n++] = (char)c;
		}
	}
	out[n] = '\0';
	strncat(out, (info->flags & dlpDBFlagResource) ? ".prc" : ".pdb", size - strlen(out) - 1);
}

/* Datenbanken, die nicht in eine Sicherung gehören - dieselben wie bei
 * pilot-xfer: Datenbanken dieser Creator setzen manche Palm OS 5-Geräte beim
 * Lesen zurück oder sind nur Caches (PACE), "Unsaved Preferences" ist ein
 * Arbeitsstand des Systems. */
#define FOURCC(a, b, c, d) \
	(((unsigned long)(a) << 24) | ((unsigned long)(b) << 16) | ((unsigned long)(c) << 8) | (unsigned long)(d))

static int skip_in_backup(const struct DBInfo *info)
{
	static const unsigned long creators[] = {
		FOURCC('p', 'p', 'p', '_'), FOURCC('u', '8', 'E', 'Z'),
		FOURCC('P', 'M', 'H', 'a'), FOURCC('P', 'M', 'N', 'e'),	/* Phone Link Update */
		FOURCC('F', 'n', 't', '1'),					/* Hires-Fonts */
		FOURCC('m', 'o', 'd', 'm'), FOURCC('a', '6', '8', 'k')		/* PACE-Cache */
	};
	size_t i;

	for (i = 0; i < sizeof(creators) / sizeof(creators[0]); i++)
		if (info->creator == creators[i])
			return 1;
	return strcmp(info->name, "Unsaved Preferences") == 0;
}

/* Datenbanken, die der Palm vor dem Kopieren schützt: Kopierschutz gesetzt
 * und das Sicherungsbit nicht - beides sagt "bleibt auf dem Gerät". So legt
 * CradleSync seine Schlüsseldatenbank CradleAuthDB an (der private Schlüssel
 * des Palms); sie wird zusätzlich beim Namen genannt, wie bei Cradles eigenem
 * Werkzeug, samt den Creators des alten Cradle Auth und der wartenden
 * CradleSync-Aktualisierung. Anders als skip_in_backup wird das gemeldet. */
static int protected_in_backup(const struct DBInfo *info)
{
	/* Kopierschutz ohne Sicherungsbit allein reicht nicht: so sind auch
	 * die Systembausteine eines T|X (WiFiLib, die Media-Plugins) und
	 * gekaufte Musik markiert, und die gehören in die Sicherung. Nur ein
	 * Schlüssel (Typ key_) bleibt deshalb auf dem Gerät. */
	if ((info->flags & dlpDBFlagCopyPrevention) && !(info->flags & dlpDBFlagBackup)
	    && info->type == FOURCC('k', 'e', 'y', '_'))
		return 1;
	if (info->creator == FOURCC('C', 'r', 'A', 'u') || info->creator == FOURCC('C', 'r', 'S', 'n'))
		return 1;
	return strcmp(info->name, "CradleAuthDB") == 0;
}

static void emit_backup_failed(const char *name, const char *reason, int sd)
{
	emit_begin("backupFailed");
	emit_str("file", name, 0);
	emit_str("reason", reason, 0);
	if (sd >= 0) {
		emit_int("error", pi_error(sd));
		emit_int("palmOSError", pi_palmos_error(sd));
	}
	emit_end();
}

/* ---- Palm OS Cobalt: erweiterte Datenbanken ---------------------------- */

/* Cobalt (Palm OS 6) kennt neben den klassischen zwei weitere Familien von
 * Datenbanken, in der Liste an den Flags zu erkennen: 0x1000 (Schema) und
 * 0x2000 ohne 0x1000 (erweitert, etwa BootAppDB auf einem frischen Speicher).
 * Eine erweiterte Datenbank öffnet Cobalts DLServer nur, wenn OpenDB (0x17)
 * ein zweites Argument trägt: Kennung 0x21, genau 4 Bytes, der Creator der
 * Datenbank. Ohne dieses Argument sucht er mit den Aufrufen für klassische
 * Datenbanken und antwortet mit Palm-OS-Fehler 5, gleich welche Modusbits
 * gesetzt sind. Beobachtet an Cobalts DLServer in der Nachstellung:
 *   17 02  20 0c 00 80 "BootAppDB\0"  21 04 70 73 79 73   -> Handle 1
 * Schema-Datenbanken gehen über eigene Befehle (0x80/0x81) und bleiben außen
 * vor. pilot-links dlp_OpenDB hat kein zweites Argument, darum hier der rohe
 * Aufruf, gebaut wie dlp.c seine eigenen Anfragen baut: dlp_request_new
 * nummeriert die Argumente von 0x20 an durch, das zweite heißt also 0x21.
 *
 * Palm OS Cobalt (Palm OS 6) has two more database families beside the
 * classic ones, told apart by the list flags: 0x1000 (schema) and 0x2000
 * without 0x1000 (extended, e.g. BootAppDB on a fresh store). Cobalt's
 * DLServer opens an extended database only when OpenDB (0x17) carries a
 * second argument: id 0x21, exactly 4 bytes, the database's creator. Without
 * it the server uses the lookup calls for classic databases and answers
 * Palm OS error 5 whatever the mode bits. Observed in a replay against
 * Cobalt's DLServer (see the request bytes above). Schema databases use
 * their own commands (0x80/0x81) and are out of scope. pilot-link's
 * dlp_OpenDB has no second argument, hence the raw request, built the way
 * dlp.c builds its own: dlp_request_new numbers the arguments from 0x20
 * on, so the second one is 0x21. */
#define DLP_REQUEST_DATA(req, arg, offset) (&(req)->argv[arg]->data[offset])
#define DLP_RESPONSE_DATA(res, arg, offset) (&(res)->argv[arg]->data[offset])

static int is_extended_db(const struct DBInfo *info)
{
	return (info->flags & dlpDBFlagExtended) && !(info->flags & dlpDBFlagSchema);
}

/* OpenDB mit dem Creator als zweitem Argument; liest das Handle aus der
 * Antwort wie dlp_OpenDB. Modus 0x80 (lesen), wie in der Nachstellung. */
static int open_extended_db(int sd, int cardno, const struct DBInfo *info, int *dbhandle)
{
	struct dlpRequest *req;
	struct dlpResponse *res = NULL;
	size_t name_len = strlen(info->name);
	int result;

	pi_reset_errors(sd);
	req = dlp_request_new(dlpFuncOpenDB, 2, 2 + name_len + 1, (size_t)4);
	if (req == NULL)
		return pi_set_error(sd, PI_ERR_GENERIC_MEMORY);
	set_byte(DLP_REQUEST_DATA(req, 0, 0), cardno);
	set_byte(DLP_REQUEST_DATA(req, 0, 1), dlpOpenRead);
	memcpy(DLP_REQUEST_DATA(req, 0, 2), info->name, name_len + 1);
	set_long(DLP_REQUEST_DATA(req, 1, 0), info->creator);

	result = dlp_exec(sd, req, &res);
	dlp_request_free(req);
	if (result > 0)
		*dbhandle = get_byte(DLP_RESPONSE_DATA(res, 0, 0));
	dlp_response_free(res);
	return result;
}

enum extended_stage { EXT_OK, EXT_OPEN_FAILED, EXT_READ_FAILED };

/* Sichert eine erweiterte Datenbank in pf: öffnen mit Creator, danach
 * dieselben Aufrufe wie pi_file_retrieve (ReadOpenDBInfo, AppInfo-Block,
 * Datensätze oder Ressourcen der Reihe nach, CloseDB). Ob die klassischen
 * Leseaufrufe bei einer erweiterten Datenbank mit Inhalt funktionieren,
 * ist offen - darum sagt das Ergebnis, ob das Öffnen oder das Lesen
 * scheiterte. Auf einem frischen Speicher hat BootAppDB keinen Eintrag. */
static enum extended_stage retrieve_extended_db(pi_file_t *pf, int sd, const struct DBInfo *info,
						progress_func report_progress)
{
	int db = -1, records = 0, result;
	pi_buffer_t *buffer;
	pi_progress_t progress;
	int j;

	if (open_extended_db(sd, 0, info, &db) < 0)
		return EXT_OPEN_FAILED;
	buffer = pi_buffer_new(DLP_BUF_SIZE);
	if (buffer == NULL) {
		dlp_CloseDB(sd, db);
		return EXT_READ_FAILED;
	}
	if (dlp_ReadOpenDBInfo(sd, db, &records) < 0)
		goto fail;

	memset(&progress, 0, sizeof(progress));
	progress.type = PI_PROGRESS_RECEIVE_DB;
	progress.data.db.pf = pf;
	progress.data.db.size.numRecords = records;

	/* der AppInfo-Block ist freiwillig: fehlt er, meldet der Palm einen
	 * Fehler, und die Datei bekommt keinen (wie bei pi_file_retrieve) */
	result = dlp_ReadAppBlock(sd, db, 0, DLP_BUF_SIZE, buffer);
	if (result > 0) {
		pi_file_set_app_info(pf, buffer->data, (size_t)result);
		progress.transferred_bytes += result;
		report_progress(sd, &progress);
	}

	for (j = 0; j < records; j++) {
		if (info->flags & dlpDBFlagResource) {
			int resource_id;
			unsigned long type;

			if (dlp_ReadResourceByIndex(sd, db, j, buffer, &type, &resource_id) < 0)
				goto fail;
			if (pi_file_append_resource(pf, buffer->data, buffer->used, type, resource_id) < 0)
				goto fail;
		} else {
			int attr, category;
			recordid_t id;

			if (dlp_ReadRecordByIndex(sd, db, j, buffer, &id, &attr, &category) < 0)
				goto fail;
			/* archiviert oder gelöscht: nicht wiederherstellbar, wie pi_file_retrieve */
			if (!(attr & (dlpRecAttrArchived | dlpRecAttrDeleted))
			    && pi_file_append_record(pf, buffer->data, buffer->used, attr, category, id) < 0)
				goto fail;
		}
		progress.transferred_bytes += buffer->used;
		progress.data.db.transferred_records++;
		report_progress(sd, &progress);
	}
	pi_buffer_free(buffer);
	if (dlp_CloseDB(sd, db) < 0)
		return EXT_READ_FAILED;
	return EXT_OK;

fail:
	pi_buffer_free(buffer);
	dlp_CloseDB(sd, db);
	return EXT_READ_FAILED;
}

/* "backup <Ordner>": die Datenbanken im RAM nach <Ordner> sichern, eine
 * .prc/.pdb je Datenbank. Seit der letzten Sicherung unverändert (das
 * Änderungsdatum auf dem Palm ist das Dateidatum, wie bei pilot-xfer -u):
 * übersprungen. Geschrieben wird über <Datei>.part, damit ein abgebrochener
 * HotSync die vorige Sicherung einer Datenbank nicht zerstört.
 * Ereignisse: backupStarted (mit Gesamtzahl), je Datenbank backingUp und
 * backedUp / backupUnchanged / backupFailed, am Ende backupFinished; vorweg
 * backupSkipped für jede Datenbank, die der Palm schützt, und für jede
 * Schema-Datenbank eines Cobalt-Palms (Grund "schema": eigene Befehle). */
static void backup(int sd, const char *dir)
{
	struct DBInfo *list = NULL;
	int count = 0, capacity = 0, index = 0, i;
	int saved = 0, unchanged = 0, failed = 0;
	pi_buffer_t *buffer;

	if (mkdir(dir, 0755) != 0 && errno != EEXIST) {
		emit_error("backup", "cannot create %s (%s)", dir, strerror(errno));
		return;
	}
	buffer = pi_buffer_new(sizeof(struct DBInfo));
	if (buffer == NULL) {
		emit_error("backup", "out of memory");
		return;
	}

	/* erst die ganze Liste: die Gesamtzahl für den Fortschritt. Ihr Ende
	 * meldet der Palm als "nicht gefunden". */
	while (dlp_ReadDBList(sd, 0, dlpDBListRAM, index, buffer) >= 0) {
		struct DBInfo info;

		memcpy(&info, buffer->data, sizeof(struct DBInfo));
		index = info.index + 1;
		if (skip_in_backup(&info))
			continue;
		if (protected_in_backup(&info)) {
			char name[256];

			file_name_for(name, sizeof(name), &info);
			emit_begin("backupSkipped");
			emit_str("file", name, 0);
			emit_str("reason", "protected", 0);
			emit_end();
			continue;
		}
		if (info.flags & dlpDBFlagSchema) {
			char name[256];

			file_name_for(name, sizeof(name), &info);
			emit_begin("backupSkipped");
			emit_str("file", name, 0);
			emit_str("reason", "schema", 0);
			emit_end();
			continue;
		}
		if (count == capacity) {
			struct DBInfo *grown;

			capacity = capacity ? capacity * 2 : 64;
			grown = realloc(list, capacity * sizeof(struct DBInfo));
			if (grown == NULL) {
				emit_error("backup", "out of memory");
				free(list);
				pi_buffer_free(buffer);
				return;
			}
			list = grown;
		}
		list[count++] = info;
	}
	pi_buffer_free(buffer);
	if (!pi_socket_connected(sd)) {
		emit_error("backup", "the Palm does not answer any more");
		free(list);
		return;
	}

	emit_begin("backupStarted");
	emit_str("directory", dir, 0);
	emit_int("total", count);
	emit_end();

	for (i = 0; i < count; i++) {
		struct DBInfo info = list[i];
		char name[256], path[PATH_MAX], part[PATH_MAX + 8];
		struct stat sbuf;
		struct utimbuf times;
		pi_file_t *pf;

		/* "Abbrechen" auf dem Palm beendet die Sicherung */
		if (!pi_socket_connected(sd) || dlp_OpenConduit(sd) < 0) {
			emit_error("backup", "cancelled on the Palm or connection lost");
			break;
		}

		file_name_for(name, sizeof(name), &info);
		snprintf(path, sizeof(path), "%s/%s", dir, name);

		if (stat(path, &sbuf) == 0 && sbuf.st_mtime == info.modifyDate) {
			emit_begin("backupUnchanged");
			emit_str("file", name, 0);
			emit_int("index", i + 1);
			emit_end();
			unchanged++;
			continue;
		}

		emit_begin("backingUp");
		emit_str("file", name, 0);
		emit_int("index", i + 1);
		emit_int("total", count);
		emit_end();

		/* geöffnet und schreibgeschützt gehören nicht in die Datei */
		info.flags &= ~(dlpDBFlagOpen | dlpDBFlagReadOnly);
		snprintf(part, sizeof(part), "%s.part", path);
		pf = pi_file_create(part, &info);
		if (pf == NULL) {
			emit_backup_failed(name, "unwritableFile", -1);
			failed++;
			continue;
		}
		if (is_extended_db(&info)) {
			enum extended_stage stage = retrieve_extended_db(pf, sd, &info, install_progress);

			if (stage != EXT_OK) {
				char reason[96];

				snprintf(reason, sizeof(reason),
					 stage == EXT_OPEN_FAILED
					 ? "extended database: open failed (Palm OS error %d)"
					 : "extended database: open succeeded, read failed (Palm OS error %d)",
					 pi_palmos_error(sd));
				emit_backup_failed(name, reason, sd);
				pi_file_close(pf);
				unlink(part);
				failed++;
				continue;
			}
		} else if (pi_file_retrieve(pf, sd, 0, install_progress) < 0) {
			emit_backup_failed(name, "palmError", sd);
			pi_file_close(pf);
			unlink(part);
			failed++;
			continue;
		}
		if (pi_file_close(pf) < 0) {	/* schreibt die Datei */
			emit_backup_failed(name, "unwritableFile", -1);
			unlink(part);
			failed++;
			continue;
		}
		/* Dateidatum = Änderungsdatum auf dem Palm: so erkennt die nächste
		 * Sicherung, dass sich nichts geändert hat */
		times.actime = info.createDate;
		times.modtime = info.modifyDate;
		utime(part, &times);
		if (rename(part, path) != 0) {
			emit_backup_failed(name, "unwritableFile", -1);
			unlink(part);
			failed++;
			continue;
		}

		emit_begin("backedUp");
		emit_str("file", name, 0);
		emit_int("bytes", stat(path, &sbuf) == 0 ? (long)sbuf.st_size : 0);
		emit_end();
		saved++;
	}
	free(list);

	emit_begin("backupFinished");
	emit_int("saved", saved);
	emit_int("unchanged", unchanged);
	emit_int("failed", failed);
	emit_end();
}

/* ---- ROM --------------------------------------------------------------- */

/* Bytes je RPC-Aufruf und wie oft dabei nach "Abbrechen" auf dem Palm und
 * nach dem Fortschritt geschaut wird - wie pilot-getrom */
#define ROM_CHUNK		256
#define ROM_CANCEL_EVERY	8
#define ROM_PROGRESS_EVERY	16

/* Text unten auf den Bildschirm des Palms (WinDrawChars). Nur zur Anzeige:
 * scheitert es, geht das Auslesen trotzdem weiter. dlp_RPC schreibt die
 * Daten jedes Zeiger-Parameters nach dem Aufruf zurück - der Text muss
 * daher in einem beschreibbaren Puffer liegen, nicht in einer Konstante. */
static void draw_on_palm(int sd, const char *text, int x)
{
	struct RPC_params p;
	char buffer[64];
	size_t len = strlen(text);

	if (len >= sizeof(buffer))
		len = sizeof(buffer) - 1;
	memcpy(buffer, text, len);
	buffer[len] = '\0';
	PackRPC(&p, 0xA220, RPC_IntReply, RPC_Ptr(buffer, len),
		RPC_Short(len), RPC_Short(x), RPC_Short(28), RPC_End);
	dlp_RPC(sd, &p, NULL);
}

/* "getrom <Ordner>": das ROM des Palms lesen, über DLP-RPC wie pilot-getrom
 * (MemMove aus dem ROM in 256-Byte-Stücken). Palm OS 5 kennt diese RPCs
 * nicht mehr und stürzt ab - dort nur "romUnsupported". Anders als
 * pilot-getrom bricht jeder RPC-Fehler ab, statt Müll in die Datei zu
 * schreiben; geschrieben wird über <Datei>.part.
 * Ereignisse: romStarted (Datei, Version, Größe), romProgress (Bytes),
 * romFinished oder romUnsupported, sonst error. */
static void get_rom(int sd, const char *dir)
{
	struct RPC_params p;
	unsigned long feature, rom_start, rom_length, offset = 0, chunks = 0;
	int major, minor, bugfix;
	char version[32], name[64], path[PATH_MAX], part[PATH_MAX + 8];
	unsigned char buffer[ROM_CHUNK];
	FILE *out;

	if (dlp_ReadFeature(sd, FOURCC('p', 's', 'y', 's'), 1, &feature) < 0) {
		emit_error("rom", "cannot read the Palm OS version");
		return;
	}
	major = (int)(((feature >> 28) & 0xF) * 10 + ((feature >> 24) & 0xF));
	minor = (int)((feature >> 20) & 0xF);
	bugfix = (int)((feature >> 16) & 0xF);
	snprintf(version, sizeof(version), "%d.%d.%d", major, minor, bugfix);

	if (major >= 5) {
		emit_begin("romUnsupported");
		emit_str("version", version, 0);
		emit_end();
		return;
	}
	if (mkdir(dir, 0755) != 0 && errno != EEXIST) {
		emit_error("rom", "cannot create %s (%s)", dir, strerror(errno));
		return;
	}

	/* Anfang und Länge des ROM (Karte 0) */
	PackRPC(&p, 0xA23E, RPC_IntReply, RPC_Long(0xFFFFFFFF), RPC_End);
	if (dlp_RPC(sd, &p, &rom_start) < 0) {
		emit_error("rom", "cannot find the ROM (%d)", pi_error(sd));
		return;
	}
	PackRPC(&p, 0xA23E, RPC_IntReply, RPC_Long(rom_start), RPC_End);
	if (dlp_RPC(sd, &p, &rom_length) < 0) {
		emit_error("rom", "cannot read the ROM size (%d)", pi_error(sd));
		return;
	}
	/* Palm OS 3.0 meldet 1 MB für ein ROM von 2 MB (wie pilot-getrom) */
	if (major == 3 && minor == 0 && rom_length == 0x100000)
		rom_length = 0x200000;
	if (rom_length == 0 || rom_length > 0x4000000) {
		emit_error("rom", "implausible ROM size %lu", rom_length);
		return;
	}

	snprintf(name, sizeof(name), "PalmOS-%s.rom", version);
	snprintf(path, sizeof(path), "%s/%s", dir, name);
	snprintf(part, sizeof(part), "%s.part", path);
	out = fopen(part, "wb");
	if (out == NULL) {
		emit_error("rom", "cannot write %s (%s)", part, strerror(errno));
		return;
	}

	emit_begin("romStarted");
	emit_str("file", name, 0);
	emit_str("version", version, 0);
	emit_int("total", (long)rom_length);
	emit_end();

	/* Bildschirm des Palms leeren (WinEraseWindow), dann der Hinweis */
	PackRPC(&p, 0xA164, RPC_IntReply, RPC_Byte(1), RPC_End);
	dlp_RPC(sd, &p, NULL);
	draw_on_palm(sd, "Downloading ROM ...", 0);

	while (offset < rom_length) {
		unsigned long len = rom_length - offset;

		if (len > ROM_CHUNK)
			len = ROM_CHUNK;
		PackRPC(&p, 0xA026, RPC_IntReply, RPC_Ptr(buffer, len),
			RPC_Long(rom_start + offset), RPC_Long(len), RPC_End);
		if (dlp_RPC(sd, &p, NULL) < 0) {
			emit_error("rom", "reading the ROM at %lu failed (%d)", offset, pi_error(sd));
			break;
		}
		if (fwrite(buffer, 1, len, out) != len) {
			emit_error("rom", "cannot write %s (%s)", part, strerror(errno));
			break;
		}
		offset += len;
		chunks++;

		if (chunks % ROM_CANCEL_EVERY == 0 && dlp_OpenConduit(sd) < 0) {
			emit_error("rom", "cancelled on the Palm or connection lost");
			break;
		}
		if (chunks % ROM_PROGRESS_EVERY == 0 || offset == rom_length) {
			char text[32];

			emit_begin("romProgress");
			emit_int("bytes", (long)offset);
			emit_end();
			if (chunks % (ROM_PROGRESS_EVERY * 16) == 0) {
				snprintf(text, sizeof(text), "%lu KB", offset / 1024);
				draw_on_palm(sd, text, 110);
			}
		}
	}

	if (fclose(out) != 0 && offset == rom_length) {
		emit_error("rom", "cannot write %s (%s)", part, strerror(errno));
		offset = 0;
	}
	if (offset < rom_length) {
		unlink(part);
		return;
	}
	if (rename(part, path) != 0) {
		emit_error("rom", "cannot write %s (%s)", path, strerror(errno));
		unlink(part);
		return;
	}
	emit_begin("romFinished");
	emit_str("file", name, 0);
	emit_int("bytes", (long)rom_length);
	emit_end();
}

/* ---- Relay: the session goes to a desktop on the network ---------------- */

/* "relay HOST[:PORT]": the Palm on the cradle is handed to a network
 * HotSync server (Cradle's airlock, or any NetSync desktop), the way
 * Palm's LANSync did it. The server runs the session and its conduits;
 * this tool only moves DLP packets: one request from the server to the
 * Palm, the Palm's reply back, until the server ends the session
 * (dlp_EndOfSync) or either side hangs up. Nothing in the traffic is
 * interpreted beyond what framing needs. Modelled on pilot-link's
 * pilot-nredir; the socket is adopted by hand (as Cradle's worker does
 * for "--fd") because pi_connect() knows no port but 14238.
 *
 * While the server thinks (approval, conduits), the Palm hears a tickle
 * every few seconds, as it would from a slow desktop; after
 * RELAY_IDLE_LIMIT seconds without a request the relay gives up. */

#define RELAY_TICKLE_S     5
#define RELAY_IDLE_LIMIT_S 600
#define RELAY_REPORT_EVERY 25

/* set once a relayed session is over: the Palm has already had its
 * EndOfSync from the server (or the link is gone) - main() sends none */
static int session_relayed = 0;

/* Splits "host", "host:port" or "[v6]:port"; the port defaults to 14238. */
static int relay_parse_target(const char *target, char host[256], char service[16])
{
	const char *colon, *end;
	size_t len;

	strcpy(service, "14238");
	if (target[0] == '[' && (end = strchr(target, ']')) != NULL) {
		len = (size_t)(end - target - 1);
		colon = end[1] == ':' ? end + 1 : NULL;
		target++;
	} else {
		colon = strrchr(target, ':');
		len = colon ? (size_t)(colon - target) : strlen(target);
	}
	if (len == 0 || len >= 256) {
		emit_error("relay", "usage: relay HOST[:PORT]");
		return 0;
	}
	memcpy(host, target, len);
	host[len] = '\0';
	if (colon != NULL) {
		if (colon[1] == '\0' || strlen(colon + 1) >= 16) {
			emit_error("relay", "usage: relay HOST[:PORT]");
			return 0;
		}
		strcpy(service, colon + 1);
	}
	return 1;
}

/* Opens the plain TCP connection. */
static int relay_connect(const char *host, const char *service)
{
	struct addrinfo hints, *res, *ai;
	int fd = -1, err;

	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	err = getaddrinfo(host, service, &hints, &res);
	if (err != 0) {
		emit_error("relay", "cannot resolve %s: %s", host, gai_strerror(err));
		return -1;
	}
	for (ai = res; ai != NULL; ai = ai->ai_next) {
		fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
		if (fd < 0)
			continue;
		if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0)
			break;
		close(fd);
		fd = -1;
	}
	freeaddrinfo(res);
	if (fd < 0) {
		emit_error("relay", "cannot connect to %s:%s (%s)", host, service, strerror(errno));
		return -1;
	}
	{
		int one = 1;
		setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
		/* a server that is gone shows as an error, not as SIGPIPE */
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
	}
	return fd;
}

/* Turns the connected descriptor into a libpisock NET socket on the
 * Palm's side of the protocol: pi_bind() builds the device and protocol
 * stack (its ephemeral listener is replaced by the connection), then the
 * NetSync handshake is sent as a Palm sends it, and the socket is marked
 * as connected by initiating - so every request's transaction ID is
 * echoed in the reply, as the server expects from a Palm. */
static int relay_adopt(int fd)
{
	int sd, split = 0, chunksize = 0, honor = 0;
	size_t len;
	pi_socket_t *ps;

	sd = pi_socket(PI_AF_PILOT, PI_SOCK_STREAM, PI_PF_NET);
	if (sd < 0) {
		emit_error("relay", "unable to create the network socket");
		close(fd);
		return -1;
	}
	if (pi_bind(sd, "net:any:0") < 0) {
		emit_error("relay", "unable to set up the network device");
		pi_close(sd);
		close(fd);
		return -1;
	}
	ps = find_pi_socket(sd);
	if (ps == NULL) {
		emit_error("relay", "socket vanished");
		pi_close(sd);
		close(fd);
		return -1;
	}
	/* dup2(fd, ps->sd): the listener goes away, fd is closed afterwards */
	if (pi_socket_setsd(ps, fd) < 0) {
		emit_error("relay", "cannot adopt the connection (%s)", strerror(errno));
		pi_close(sd);
		return -1;
	}
	ps->cmd = PI_CMD_NET;
	pi_socket_init(ps);

	/* as pi_inet_accept(): never split writes, on both protocol stacks */
	len = sizeof(split);
	pi_setsockopt(ps->sd, PI_LEVEL_NET, PI_NET_SPLIT_WRITES, &split, &len);
	len = sizeof(chunksize);
	pi_setsockopt(ps->sd, PI_LEVEL_NET, PI_NET_WRITE_CHUNKSIZE, &chunksize, &len);
	ps->command ^= 1;
	len = sizeof(split);
	pi_setsockopt(ps->sd, PI_LEVEL_NET, PI_NET_SPLIT_WRITES, &split, &len);
	len = sizeof(chunksize);
	pi_setsockopt(ps->sd, PI_LEVEL_NET, PI_NET_WRITE_CHUNKSIZE, &chunksize, &len);
	ps->command ^= 1;

	/* the handshake runs as pi_inet_connect() would run it */
	ps->state = PI_SOCK_CONN_INIT;
	ps->command = 0;
	if (net_tx_handshake(ps) < 0) {
		emit_error("relay", "NetSync handshake with the server failed (%d)", pi_error(sd));
		pi_close(sd);
		return -1;
	}
	/* no 30-second limit on waiting for the next request: the relay
	 * waits itself (poll), tickling the Palm meanwhile */
	len = sizeof(honor);
	pi_setsockopt(sd, PI_LEVEL_SOCK, PI_SOCK_HONOR_RX_TIMEOUT, &honor, &len);
	return sd;
}

/* Waits for the server's next request, keeping the Palm awake. Returns
 * 1 when something is there to read, 0 when the Palm went away, -1 after
 * RELAY_IDLE_LIMIT_S without a word from the server. */
static int relay_wait(int sd, int netfd)
{
	struct pollfd pfd = { .fd = netfd, .events = POLLIN };
	int waited = 0;

	for (;;) {
		int ready = poll(&pfd, 1, RELAY_TICKLE_S * 1000);
		if (ready > 0)
			return 1;
		if (ready < 0 && errno != EINTR)
			return 1;	/* let pi_read report what is wrong */
		waited += RELAY_TICKLE_S;
		if (waited >= RELAY_IDLE_LIMIT_S)
			return -1;
		if (pi_tickle(sd) < 0 || !pi_socket_connected(sd))
			return 0;
	}
}

/* ---- Relay: the Mac answers Cradle's authenticator for the Palm --------- */

/* Cradle's airlock lets a Palm in only when it proves itself: on first
 * contact it asks the Palm, through DLP CallApplication for CradleSync
 * (creator CrSy), to make an Ed25519 key and keep the public half; every
 * later session starts with a challenge the Palm signs (Cradle's
 * docs/device-auth.md). A Palm OS 3 or 4 device cannot run CradleSync, so
 * for it the Mac answers those calls here, with a key the app keeps per
 * Palm in the Keychain and hands over with "relaykey". To the airlock that
 * is a Palm with an authenticator like any other; the key says "this
 * Palm's HotSync came through that Mac", which is as much as a device with
 * no place for a key can be made to say.
 *
 *   relaykey HEX           the Palm's Ed25519 seed (32 bytes, hex)
 *   relaytls PORT NAME PIN the Secure transport record the airlock issued
 *                          (TLS port, server name, SPKI pin as hex): with
 *                          it "relay" comes in over TLS to that port
 *   relaypair CODE         a pair code typed on the Mac (action 5)
 *
 * Calls answered (the wire format is CradleSync's, palm/sync/auth/auth.h):
 *   1 enrol      32 bytes of entropy -> CRA1 + public key
 *   2 sign       CRA1 + nonce + user ID + PC ID (44 bytes) -> signature
 *   3 info       -> CRA1 + version + key fingerprint
 *   4 transport  CRA1 + port + name + pin -> CRA1; reported as relayAuth
 *   5 pair       -> CRA1 + the pair code, CRA1 alone without one
 *   6 paired     CRA1 + accepted -> CRA1; the code is forgotten
 * Unlike CradleSync, enrol with a key already made answers with that key:
 * the key is the Mac's to show, and a device record reset in the console
 * must be able to enrol it again without a reset here.
 *
 * As CradleSync from build 138: once the transport record is held, a
 * plain session gets no signature (CRA_ERR_PLAIN, 7) and no new record,
 * because whoever answers at the plain port could be anyone. The app
 * never relays plainly with a record held; the refusal is for a tool
 * driven by hand. */

#define CRA_ACTION_ENROL     1
#define CRA_ACTION_SIGN      2
#define CRA_ACTION_INFO      3
#define CRA_ACTION_TRANSPORT 4
#define CRA_ACTION_PAIR      5
#define CRA_ACTION_PAIRED    6
#define CRA_OK          0
#define CRA_ERR_PARAM   1
#define CRA_ERR_NO_KEY  3
#define CRA_ERR_PLAIN   7
#define CRA_VERSION     1
#define CRA_PAIR_MAX    16
#define CRA_SIGN_PARAM_LEN 44
#define CRA_TRANSPORT_MIN (4 + 2 + 1 + 32)

static struct {
	int has_key;
	uint8_t secret[64];	/* Monocypher's expanded secret key */
	uint8_t public[32];
	int has_transport;
	unsigned port;
	char name[64];
	uint8_t pin[32];
	char pair[CRA_PAIR_MAX + 1];
	int secure;		/* this relay runs inside TLS */
} relay_auth;

static int hex_nibble(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

/* Decodes exactly `len` bytes of hex; 0 on anything else. */
static int hex_decode(const char *hex, uint8_t *out, size_t len)
{
	size_t i;

	for (i = 0; i < len; i++) {
		int hi = hex_nibble(hex[2 * i]), lo = hex[2 * i] ? hex_nibble(hex[2 * i + 1]) : -1;
		if (hi < 0 || lo < 0)
			return 0;
		out[i] = (uint8_t)(hi << 4 | lo);
	}
	return hex[2 * len] == '\0';
}

static void emit_hex(const char *key, const uint8_t *data, size_t len)
{
	static const char digits[] = "0123456789abcdef";
	size_t i;

	printf(",\"%s\":\"", key);
	for (i = 0; i < len; i++) {
		putchar(digits[data[i] >> 4]);
		putchar(digits[data[i] & 0xF]);
	}
	putchar('"');
}

/* The fingerprint the console and CradleSync show: SHA-512 of the public
 * key, first 8 bytes. */
static void relay_fingerprint(uint8_t fp[8])
{
	uint8_t hash[64];

	crypto_sha512(hash, relay_auth.public, 32);
	memcpy(fp, hash, 8);
	crypto_wipe(hash, sizeof(hash));
}

/* "relaykey HEX": the seed; the public key follows from it. */
static void relay_set_key(const char *hex)
{
	uint8_t seed[32], fp[8];

	if (!hex_decode(hex, seed, sizeof(seed))) {
		emit_error("relay", "usage: relaykey <64 hex digits>");
		return;
	}
	crypto_ed25519_key_pair(relay_auth.secret, relay_auth.public, seed);	/* wipes seed */
	relay_auth.has_key = 1;
	relay_fingerprint(fp);
	emit_begin("relayKey");
	emit_hex("fingerprint", fp, sizeof(fp));
	emit_end();
}

/* "relaytls PORT NAME PINHEX": the Secure transport record. */
static void relay_set_transport(const char *args)
{
	char name[64], pin[80];
	unsigned port;

	if (sscanf(args, "%u %63s %79s", &port, name, pin) != 3 || port == 0 || port > 65535
	    || !hex_decode(pin, relay_auth.pin, sizeof(relay_auth.pin))) {
		emit_error("relay", "usage: relaytls <port> <server name> <64 hex digits>");
		return;
	}
	relay_auth.port = port;
	strcpy(relay_auth.name, name);
	relay_auth.has_transport = 1;
}

/* "relaypair CODE": what the user typed; "relaypair" alone forgets it. */
static void relay_set_pair(const char *code)
{
	size_t len = strcspn(code, " \t");

	if (len > CRA_PAIR_MAX) {
		emit_error("relay", "the pair code is longer than %d characters", CRA_PAIR_MAX);
		return;
	}
	memcpy(relay_auth.pair, code, len);
	relay_auth.pair[len] = '\0';
}

static int has_magic(const uint8_t *p)
{
	return p[0] == 'C' && p[1] == 'R' && p[2] == 'A' && p[3] == '1';
}

static void put_magic(uint8_t *p)
{
	p[0] = 'C'; p[1] = 'R'; p[2] = 'A'; p[3] = '1';
}

/* Is this request a CallApplication for CradleSync? Sets *action, *param
 * and *len when it is (the Palm OS 2.0+ encoding libpisock sends: one
 * argument, creator, type, action, parameter length, two reserved longs,
 * the parameter). Anything else goes to the Palm. */
static int relay_auth_request(const uint8_t *req, size_t n, unsigned *action, const uint8_t **param, size_t *len)
{
	const uint8_t *arg;
	size_t arglen;

	if (n < 4 || req[0] != dlpFuncCallApplication || req[1] != 1)
		return 0;
	if (req[2] & PI_DLP_ARG_FLAG_LONG) {
		if (n < 8)
			return 0;
		arglen = get_long(req + 4);
		arg = req + 8;
	} else if (req[2] & PI_DLP_ARG_FLAG_SHORT) {
		if (n < 6)
			return 0;
		arglen = get_short(req + 4);
		arg = req + 6;
	} else {
		arglen = req[3];
		arg = req + 4;
	}
	if (arglen < 22 || (size_t)(arg - req) + arglen > n)
		return 0;
	if (memcmp(arg, "CrSy", 4) != 0 || memcmp(arg + 4, "appl", 4) != 0)
		return 0;
	*action = get_short(arg + 8);
	*len = get_long(arg + 10);
	if (*len > arglen - 22)
		*len = arglen - 22;
	*param = arg + 22;
	return 1;
}

/* Answers one call. The reply is a DLP response as the Palm would send
 * it: function | 0x80, one argument, no error, then the argument (result
 * code, result size, two reserved longs, the result). Returns its length. */
static size_t relay_auth_answer(unsigned action, const uint8_t *param, size_t len, uint8_t *reply)
{
	uint8_t result[80], fp[8];
	size_t n = 0;
	unsigned code = CRA_OK;
	/* a plain session with a pin held: the asker is whoever answered at
	 * the server's address */
	int kept = relay_auth.has_transport && !relay_auth.secure;
	int report = 1;

	switch (action) {
	case CRA_ACTION_ENROL:
		if (len != 32) {
			code = CRA_ERR_PARAM;
		} else {
			put_magic(result);
			memcpy(result + 4, relay_auth.public, 32);
			n = 36;
		}
		break;
	case CRA_ACTION_SIGN:
		if (len != CRA_SIGN_PARAM_LEN || !has_magic(param))
			code = CRA_ERR_PARAM;
		else if (kept)
			code = CRA_ERR_PLAIN;
		else {
			crypto_ed25519_sign(result, relay_auth.secret, param, len);
			n = 64;
		}
		break;
	case CRA_ACTION_INFO:
		put_magic(result);
		set_short(result + 4, CRA_VERSION);
		relay_fingerprint(result + 6);
		n = 14;
		report = 0;
		break;
	case CRA_ACTION_TRANSPORT:
		if (len < CRA_TRANSPORT_MIN || !has_magic(param) || param[6] > 63 || 4 + 3 + (size_t)param[6] + 32 != len) {
			code = CRA_ERR_PARAM;
		} else if (kept && (get_short(param + 4) != relay_auth.port || param[6] != strlen(relay_auth.name)
			    || memcmp(param + 7, relay_auth.name, param[6]) != 0
			    || memcmp(param + 7 + param[6], relay_auth.pin, 32) != 0)) {
			code = CRA_ERR_PLAIN;
		} else {
			relay_auth.port = get_short(param + 4);
			memcpy(relay_auth.name, param + 7, param[6]);
			relay_auth.name[param[6]] = '\0';
			memcpy(relay_auth.pin, param + 7 + param[6], 32);
			relay_auth.has_transport = 1;
			put_magic(result);
			n = 4;
		}
		break;
	case CRA_ACTION_PAIR:
		put_magic(result);
		n = 4;
		if (!kept && relay_auth.pair[0] != '\0') {
			memcpy(result + 4, relay_auth.pair, strlen(relay_auth.pair));
			n += strlen(relay_auth.pair);
		}
		break;
	case CRA_ACTION_PAIRED:
		if (len != 5 || !has_magic(param)) {
			code = CRA_ERR_PARAM;
		} else {
			relay_auth.pair[0] = '\0';
			put_magic(result);
			n = 4;
		}
		break;
	default:
		code = CRA_ERR_PARAM;
	}

	if (report) {
		emit_begin("relayAuth");
		emit_int("action", (long)action);
		emit_int("code", (long)code);
		if (code == CRA_OK && action == CRA_ACTION_ENROL) {
			relay_fingerprint(fp);
			emit_hex("fingerprint", fp, sizeof(fp));
		}
		if (code == CRA_OK && action == CRA_ACTION_TRANSPORT) {
			emit_int("tlsPort", (long)relay_auth.port);
			emit_str("name", relay_auth.name, 0);
			emit_hex("pin", relay_auth.pin, sizeof(relay_auth.pin));
		}
		if (code == CRA_OK && action == CRA_ACTION_PAIRED)
			emit_int("accepted", param[4] ? 1 : 0);
		emit_end();
	}

	reply[0] = dlpFuncCallApplication | 0x80;
	reply[1] = 1;
	set_short(reply + 2, 0);
	reply[4] = 0x21;			/* the argument ID of the call, tiny form */
	reply[5] = (uint8_t)(16 + n);
	set_long(reply + 6, code);
	set_long(reply + 10, n);
	set_long(reply + 14, 0);
	set_long(reply + 18, 0);
	memcpy(reply + 22, result, n);
	crypto_wipe(result, sizeof(result));
	return 22 + n;
}

/* ---- Relay: TLS to the airlock's Secure listener ------------------------ */

/* With the transport record held, the relay comes in over TLS 1.3 to the
 * record's port: server name airlock.cradle (SNI), ALPN cradle-hotsync/1,
 * the server known by the SPKI pin in the record and nothing else (no
 * chain, no client certificate: the Palm proves itself inside the session,
 * above). NetSync runs inside unchanged. Network.framework does the TLS;
 * libpisock sees one end of a socket pair, and two queues move bytes
 * between the other end and the connection. */

#define RELAY_TLS_CONNECT_S 30

struct relay_tls {
	nw_connection_t conn;
	int fd;				/* the pump's end of the socket pair */
	dispatch_queue_t rx, tx;
	dispatch_source_t reader;
	dispatch_semaphore_t up, drained;
	int ready, failed, pin_ok;
	char why[200];
};

/* One DER tag-length header at p: its header size and content length. */
static int der_header(const uint8_t *p, size_t n, size_t *hdr, size_t *len)
{
	size_t i, k;

	if (n < 2)
		return 0;
	if ((p[1] & 0x80) == 0) {
		*hdr = 2;
		*len = p[1];
	} else {
		k = p[1] & 0x7F;
		if (k == 0 || k > 4 || n < 2 + k)
			return 0;
		*len = 0;
		for (i = 0; i < k; i++)
			*len = *len << 8 | p[2 + i];
		*hdr = 2 + k;
	}
	return *hdr + *len <= n;
}

/* The SubjectPublicKeyInfo of a DER certificate (the whole TLV, which is
 * what the pin hashes): Certificate { TBSCertificate { [0] version,
 * serial, signature, issuer, validity, subject, subjectPublicKeyInfo ... */
static int der_spki(const uint8_t *cert, size_t n, const uint8_t **spki, size_t *spkilen)
{
	size_t hdr, len, i;
	const uint8_t *p = cert, *end;

	if (!der_header(p, n, &hdr, &len) || p[0] != 0x30)
		return 0;
	p += hdr;
	end = p + len;
	if (!der_header(p, (size_t)(end - p), &hdr, &len) || p[0] != 0x30)
		return 0;
	p += hdr;
	end = p + len;
	if (p < end && p[0] == 0xA0) {		/* version, optional */
		if (!der_header(p, (size_t)(end - p), &hdr, &len))
			return 0;
		p += hdr + len;
	}
	for (i = 0; i < 5; i++) {		/* serial, signature, issuer, validity, subject */
		if (!der_header(p, (size_t)(end - p), &hdr, &len))
			return 0;
		p += hdr + len;
	}
	if (!der_header(p, (size_t)(end - p), &hdr, &len) || p[0] != 0x30)
		return 0;
	*spki = p;
	*spkilen = hdr + len;
	return 1;
}

/* Does the server's certificate carry the pinned key? */
static int relay_tls_pinned(sec_trust_t trust)
{
	SecTrustRef ref = sec_trust_copy_ref(trust);
	CFArrayRef chain;
	SecCertificateRef leaf;
	CFDataRef der;
	const uint8_t *spki;
	size_t spkilen;
	uint8_t sum[CC_SHA256_DIGEST_LENGTH];
	int ok = 0;

	if (ref == NULL)
		return 0;
	chain = SecTrustCopyCertificateChain(ref);
	if (chain != NULL && CFArrayGetCount(chain) > 0) {
		leaf = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
		der = SecCertificateCopyData(leaf);
		if (der != NULL) {
			if (der_spki(CFDataGetBytePtr(der), (size_t)CFDataGetLength(der), &spki, &spkilen)) {
				CC_SHA256(spki, (CC_LONG)spkilen, sum);
				ok = memcmp(sum, relay_auth.pin, sizeof(sum)) == 0;
			}
			CFRelease(der);
		}
	}
	if (chain != NULL)
		CFRelease(chain);
	CFRelease(ref);
	return ok;
}

static void relay_tls_fail(struct relay_tls *t, const char *why)
{
	if (!t->failed && !t->ready) {
		t->failed = 1;
		snprintf(t->why, sizeof(t->why), "%s", why);
		dispatch_semaphore_signal(t->up);
	}
}

/* Bytes from the server go into the socket pair; libpisock reads them. */
static void relay_tls_receive(struct relay_tls *t)
{
	nw_connection_receive(t->conn, 1, 65536, ^(dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t err) {
		(void)ctx;
		if (content != NULL) {
			dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buf, size_t size) {
				const uint8_t *p = buf;
				(void)region; (void)offset;
				while (size > 0) {
					ssize_t w = write(t->fd, p, size);
					if (w <= 0)
						return false;
					p += w;
					size -= (size_t)w;
				}
				return true;
			});
		}
		if (err != NULL || complete) {
			shutdown(t->fd, SHUT_WR);	/* EOF for libpisock: the server hung up */
			return;
		}
		relay_tls_receive(t);
	});
}

/* Bytes libpisock writes go to the server. */
static void relay_tls_pump_out(struct relay_tls *t)
{
	t->reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)t->fd, 0, t->tx);
	dispatch_source_set_event_handler(t->reader, ^{
		uint8_t *buf = malloc(65536);
		ssize_t n = buf != NULL ? read(t->fd, buf, 65536) : -1;
		dispatch_data_t data;

		if (n <= 0) {
			/* libpisock closed its end: what it wrote last is on its way,
			 * and the final message after it says so to the server */
			free(buf);
			dispatch_source_cancel(t->reader);
			nw_connection_send(t->conn, NULL, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(nw_error_t e) {
				(void)e;
				dispatch_semaphore_signal(t->drained);
			});
			return;
		}
		data = dispatch_data_create(buf, (size_t)n, t->tx, DISPATCH_DATA_DESTRUCTOR_FREE);
		nw_connection_send(t->conn, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t e) { (void)e; });
	});
	dispatch_resume(t->reader);
}

static struct relay_tls *relay_tls_active;

/* Opens the TLS connection; returns libpisock's end of the socket pair, or
 * -1 with the error reported. */
static int relay_tls_connect(const char *host)
{
	struct relay_tls *t;
	char service[8];
	int fds[2];
	nw_endpoint_t endpoint;
	nw_parameters_t params;

	t = calloc(1, sizeof(*t));
	if (t == NULL || socketpair(AF_UNIX, SOCK_STREAM, 0, fds) < 0) {
		emit_error("relay", "cannot set up the secure connection (%s)", strerror(errno));
		free(t);
		return -1;
	}
	t->fd = fds[1];
	t->rx = dispatch_queue_create("relay.tls.rx", DISPATCH_QUEUE_SERIAL);
	t->tx = dispatch_queue_create("relay.tls.tx", DISPATCH_QUEUE_SERIAL);
	t->up = dispatch_semaphore_create(0);
	t->drained = dispatch_semaphore_create(0);

	snprintf(service, sizeof(service), "%u", relay_auth.port);
	endpoint = nw_endpoint_create_host(host, service);
	params = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
		sec_protocol_options_t o = nw_tls_copy_sec_protocol_options(tls);
		sec_protocol_options_set_min_tls_protocol_version(o, tls_protocol_version_TLSv13);
		sec_protocol_options_add_tls_application_protocol(o, "cradle-hotsync/1");
		sec_protocol_options_set_tls_server_name(o, relay_auth.name);
		/* the pin is the whole verification: no chain, no name check */
		sec_protocol_options_set_verify_block(o, ^(sec_protocol_metadata_t md, sec_trust_t trust, sec_protocol_verify_complete_t done) {
			(void)md;
			t->pin_ok = relay_tls_pinned(trust);
			done(t->pin_ok);
		}, t->rx);
		sec_release(o);
	}, ^(nw_protocol_options_t tcp) {
		nw_tcp_options_set_no_delay(tcp, true);
	});
	t->conn = nw_connection_create(endpoint, params);
	nw_release(endpoint);
	nw_release(params);

	nw_connection_set_queue(t->conn, t->rx);
	nw_connection_set_state_changed_handler(t->conn, ^(nw_connection_state_t state, nw_error_t err) {
		char why[200];

		switch (state) {
		case nw_connection_state_ready:
			if (!t->ready) {
				t->ready = 1;
				dispatch_semaphore_signal(t->up);
			}
			break;
		case nw_connection_state_failed:
		case nw_connection_state_waiting:
			if (err != NULL) {
				if (nw_error_get_error_domain(err) == nw_error_domain_tls)
					snprintf(why, sizeof(why), "%s (TLS %d)", t->pin_ok ? "the TLS handshake failed"
						: "the server's certificate does not match the pin", nw_error_get_error_code(err));
				else
					snprintf(why, sizeof(why), "cannot reach the server (%s %d)",
						nw_error_get_error_domain(err) == nw_error_domain_dns ? "DNS" : "error",
						nw_error_get_error_code(err));
				relay_tls_fail(t, why);
			}
			if (state == nw_connection_state_failed)
				shutdown(t->fd, SHUT_RDWR);
			break;
		case nw_connection_state_cancelled:
			close(t->fd);
			break;
		default:
			break;
		}
	});
	nw_connection_start(t->conn);
	if (dispatch_semaphore_wait(t->up, dispatch_time(DISPATCH_TIME_NOW, (int64_t)RELAY_TLS_CONNECT_S * NSEC_PER_SEC)) != 0)
		relay_tls_fail(t, "no answer from the secure port");
	if (!t->ready) {
		emit_error("relay", "secure connection to %s:%u failed: %s", host, relay_auth.port, t->why);
		nw_connection_cancel(t->conn);
		close(fds[0]);
		relay_tls_active = t;	/* released with the connection, below */
		return -1;
	}
	{
		/* the ALPN the server agreed to must be Cradle's */
		nw_protocol_metadata_t pm = nw_connection_copy_protocol_metadata(t->conn, nw_protocol_copy_tls_definition());
		sec_protocol_metadata_t sm = pm != NULL ? nw_tls_copy_sec_protocol_metadata(pm) : NULL;
		const char *alpn = sm != NULL ? sec_protocol_metadata_copy_negotiated_protocol(sm) : NULL;
		int ok = alpn != NULL && strcmp(alpn, "cradle-hotsync/1") == 0;

		if (alpn != NULL)
			free((void *)alpn);
		if (sm != NULL)
			sec_release(sm);
		if (pm != NULL)
			nw_release(pm);
		if (!ok) {
			emit_error("relay", "the server does not speak cradle-hotsync/1");
			nw_connection_cancel(t->conn);
			close(fds[0]);
			relay_tls_active = t;
			return -1;
		}
	}
	relay_tls_receive(t);
	relay_tls_pump_out(t);
	relay_tls_active = t;
	return fds[0];
}

/* Ends the connection once libpisock's end is closed: after what libpisock
 * wrote last has gone out (the Palm's reply to EndOfSync), or five seconds. */
static void relay_tls_close(void)
{
	struct relay_tls *t = relay_tls_active;

	if (t == NULL)
		return;
	relay_tls_active = NULL;
	if (t->ready)
		dispatch_semaphore_wait(t->drained, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
	nw_connection_cancel(t->conn);
	/* the queues and the connection live on until their blocks are done;
	 * the process ends with the session anyway */
}

static void emit_relayed(const char *event, long packets, long bytes)
{
	emit_begin(event);
	emit_int("packets", packets);
	emit_int("bytes", bytes);
	emit_end();
}

/* Returns 1 when the Palm's session was consumed by the relay (over, one
 * way or another), 0 when nothing reached the Palm and the session can
 * go on with other commands. */
static int relay_session(int sd, const char *target)
{
	int fd, netsd, netfd, ended = 0, lost = 0;
	long packets = 0, bytes = 0, answered = 0;
	char host[256], service[16];
	pi_buffer_t *buf;
	pi_socket_t *ps;

	if (!relay_parse_target(target, host, service))
		return 0;
	/* with the Secure transport record held, the session goes over TLS to
	 * the record's port, whatever port the address names */
	relay_auth.secure = relay_auth.has_transport;
	fd = relay_auth.secure ? relay_tls_connect(host) : relay_connect(host, service);
	if (fd < 0)
		return 0;
	netsd = relay_adopt(fd);
	if (netsd < 0) {
		relay_tls_close();
		return 0;
	}
	ps = find_pi_socket(netsd);
	netfd = ps != NULL ? ps->sd : -1;

	emit_begin("relayStarted");
	emit_str("target", target, 0);
	emit_int("secure", relay_auth.secure);
	if (relay_auth.secure)
		emit_int("tlsPort", (long)relay_auth.port);
	emit_end();

	buf = pi_buffer_new(0xFFFF);
	for (;;) {
		ssize_t len;
		int wait = relay_wait(sd, netfd);

		if (wait == 0) {
			emit_error("relay", "connection lost while waiting for the server");
			lost = 1;
			break;
		}
		if (wait < 0) {
			emit_error("relay", "no request from the server for %d seconds", RELAY_IDLE_LIMIT_S);
			break;
		}

		/* one DLP request from the server ... */
		buf->used = 0;
		len = pi_read(netsd, buf, 0xFFFF);
		if (len <= 0) {
			/* the server hung up: after EndOfSync that is how it ends */
			if (!ended)
				emit_error("relay", "the server hung up (%d)", (int)len);
			break;
		}
		if (buf->used > 0 && buf->data[0] == dlpFuncEndOfSync)
			ended = 1;
		/* ... answered here when it is for the authenticator ... */
		if (relay_auth.has_key) {
			unsigned action;
			const uint8_t *param;
			size_t plen;

			if (relay_auth_request(buf->data, buf->used, &action, &param, &plen)) {
				uint8_t reply[128];
				size_t rlen = relay_auth_answer(action, param, plen, reply);

				if (pi_write(netsd, reply, rlen) < 0) {
					emit_error("relay", "the server hung up while receiving a reply");
					break;
				}
				bytes += (long)buf->used + (long)rlen;
				packets++;
				answered++;
				continue;
			}
		}
		/* ... to the Palm, and its reply back */
		if (pi_write(sd, buf->data, buf->used) < 0) {
			emit_error("relay", "connection lost while writing to the Palm");
			lost = 1;
			break;
		}
		bytes += (long)buf->used;
		buf->used = 0;
		len = pi_read(sd, buf, 0xFFFF);
		if (len < 0) {
			emit_error("relay", "connection lost while reading from the Palm");
			lost = 1;
			break;
		}
		if (pi_write(netsd, buf->data, buf->used) < 0) {
			emit_error("relay", "the server hung up while receiving a reply");
			break;
		}
		bytes += (long)buf->used;
		packets++;
		if (packets % RELAY_REPORT_EVERY == 0)
			emit_relayed("relayed", packets, bytes);
		if (ended)
			break;	/* the Palm has answered EndOfSync: the session is over */
	}
	pi_buffer_free(buf);

	/* The session is over on both sides: pi_close() would otherwise send
	 * its own EndOfSync to each of them (as pilot-nredir ends, too) */
	{
		int state = PI_SOCK_CONN_END;
		size_t size = sizeof(state);
		pi_setsockopt(netsd, PI_LEVEL_SOCK, PI_SOCK_STATE, &state, &size);
		pi_setsockopt(sd, PI_LEVEL_SOCK, PI_SOCK_STATE, &state, &size);
	}
	pi_close(netsd);
	relay_tls_close();

	emit_begin("relayFinished");
	emit_int("packets", packets);
	emit_int("bytes", bytes);
	emit_int("answered", answered);
	emit_int("ended", ended);
	emit_end();
	(void)lost;
	session_relayed = 1;
	return 1;
}

/* ---- Sitzung ------------------------------------------------------------ */

/* Für net: - libpisocks accept() kennt kein Timeout. Ein Wecker unterbricht
 * es (EINTR, ohne SA_RESTART), und das zählt dann als Timeout. */
static volatile sig_atomic_t accept_alarm_fired = 0;
static void accept_alarm(int signo) { (void)signo; accept_alarm_fired = 1; }

static int connect_palm(const char *port, int timeout)
{
	int listen_sd, sd;
	int is_net = strncmp(port, "net:", 4) == 0;

	listen_sd = pi_socket(PI_AF_PILOT, PI_SOCK_STREAM, PI_PF_DLP);
	if (listen_sd < 0) {
		emit_error("socket", "unable to create socket");
		return -1;
	}
	if (pi_bind(listen_sd, port) < 0) {
		emit_error("bind", "unable to bind to %s", port);
		pi_close(listen_sd);
		return -1;
	}
	if (pi_listen(listen_sd, 1) < 0) {
		emit_error("listen", "unable to listen on %s", port);
		pi_close(listen_sd);
		return -1;
	}

	emit_begin("listening");
	emit_str("port", port, 0);
	emit_end();

	/* Kein Palm innerhalb des Timeouts meldet libpisock je Anschluss anders:
	 * - USB: u_wait_for_device liefert 0, pi_usb_accept reicht das durch -
	 *   pi_accept_to gibt 0 zurück (nie ein gültiger Socket, das ist stdin)
	 *   und lässt den Listener offen.
	 * - seriell: PI_ERR_SOCK_TIMEOUT; bei negativen Werten hat pi_accept_to
	 *   den Listener schon selbst geschlossen. */
	if (is_net && timeout > 0) {
		struct sigaction sa;
		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = accept_alarm;
		sigaction(SIGALRM, &sa, NULL);
		accept_alarm_fired = 0;
		alarm((unsigned)timeout);
	}
	sd = pi_accept_to(listen_sd, NULL, NULL, timeout);
	if (is_net && timeout > 0) {
		alarm(0);
		if (sd < 0 && accept_alarm_fired) {
			pi_close(listen_sd);
			emit_begin("timeout");
			emit_end();
			return -2;
		}
	}
	if (sd == 0) {
		pi_close(listen_sd);
		emit_begin("timeout");
		emit_end();
		return -2;
	}
	if (sd == PI_ERR_SOCK_TIMEOUT) {
		emit_begin("timeout");
		emit_end();
		return -2;
	}
	if (sd < 0) {
		emit_error("accept", "error accepting data on %s (%d)", port, sd);
		return -1;
	}
	return sd;
}

/* Der beim Verbinden gelesene Benutzer: "setuser" ändert nur Name und ID
 * und schreibt die übrigen Felder unverändert zurück. */
static struct PilotUser palm_user;

static int report_identity(int sd)
{
	struct SysInfo sys;
	struct PilotUser user;

	if (dlp_ReadSysInfo(sd, &sys) < 0) {
		emit_error("sysinfo", "unable to read system info");
		return -1;
	}
	if (dlp_ReadUserInfo(sd, &user) < 0) {
		emit_error("userinfo", "unable to read user info");
		return -1;
	}

	palm_user = user;

	emit_begin("connected");
	emit_str("user", user.username, 1);
	emit_int("userId", (long)user.userID);
	emit_int("romVersion", (long)sys.romVersion);
	/* die DLP-Version des Palms: 1.x bis Palm OS 5, 2.1 bei Cobalt */
	emit_int("dlpMajor", (long)sys.dlpMajorVersion);
	emit_int("dlpMinor", (long)sys.dlpMinorVersion);
	/* auch hier, nicht nur in syncInfo: die App entscheidet beim Verbinden,
	 * was dieser HotSync tut, und braucht dafür den letzten PC */
	emit_int("lastSyncPC", (long)user.lastSyncPC);
	/* CradleSync (Cradle-Server, github lasergirl-ca): ein Palm, den auch
	 * ein Cradle abgleicht. Die App lässt dann den PIM-Abgleich aus, wenn
	 * zuletzt der Cradle abgeglichen hat. */
	{
		struct DBInfo info;
		if (dlp_FindDBInfo(sd, 0, 0, "CradleSync", 0, 0, &info) >= 0)
			emit_int("cradleSync", 1);
	}
	/* DateFix (Epoche verschoben, damit der Palm nach 2031 weiterläuft):
	 * seine Einstellung ist 6 Bytes - Version(2) Startjahr(2) an(1)
	 * laufende Umstellung(1). Ist es an, sieht der HotSync alle Daten um
	 * Startjahr - 1904 Jahre verschoben, und die Uhr ebenso. */
	{
		unsigned char pref[16];
		size_t size = 0;
		int version = 0;
		if (dlp_ReadAppPreference(sd, 0x44744678UL /* 'DtFx' */, 0, 1, sizeof(pref), pref, &size, &version) >= 0
		    && size == 6 && version == 2 && pref[4] != 0) {
			int year = (pref[2] << 8) | pref[3];
			/* DateFix erlaubt 1904 … 1972 in Viererschritten; alles andere ist kaputt */
			if (year >= 1904 && year <= 1972 && (year - 1904) % 4 == 0)
				emit_int("dateFixStartYear", (long)year);
		}
	}
	emit_end();

	/* Für den Abgleich: welcher PC zuletzt abgeglichen hat (0: keiner oder
	 * unbekannt) und wann. Weicht die PC-ID von der eigenen ab, taugen die
	 * Änderungsmarken des Palms nicht - dann langsamer Abgleich. */
	emit_begin("syncInfo");
	emit_int("lastSyncPC", (long)user.lastSyncPC);
	emit_int("lastSyncDate", (long)user.lastSyncDate);
	emit_int("successfulSyncDate", (long)user.successfulSyncDate);
	emit_end();
	return 0;
}

/* Gibt einem Palm ohne Benutzer die Identität seines Profils:
 * "setuser <ID> <Name>". Danach erkennt HotSync ihn an der ID wieder. */
static void write_user(int sd, const char *args)
{
	char *end;
	unsigned long id = strtoul(args, &end, 10);
	struct PilotUser user = palm_user;

	if (end == args || *end != ' ' || id == 0) {
		emit_error("setuser", "usage: setuser <ID> <name>");
		return;
	}
	utf8_to_cp1252(end + 1, user.username, sizeof(user.username));
	user.userID = id;
	user.viewerID = 0;
	user.lastSyncPC = 0;

	if (dlp_WriteUserInfo(sd, &user) < 0) {
		emit_error("setuser", "unable to write user info (%d, PalmOS 0x%04x)",
			pi_error(sd), pi_palmos_error(sd));
		return;
	}
	palm_user = user;

	emit_begin("userWritten");
	emit_str("user", user.username, 1);
	emit_int("userId", (long)user.userID);
	emit_end();
}

/* ---- Datensätze (PIM-Abgleich) ------------------------------------------ */

/* Die App (PalmSync) entscheidet alles; hier läuft nur DLP: eine Datenbank
 * öffnen, Datensätze und AppInfo-Block lesen und schreiben, Marken
 * zurücksetzen. Datensatzinhalte gehen als Base64 durch die JSON-Zeilen und
 * werden hier nie interpretiert. Es ist immer höchstens eine Datenbank offen. */

static int open_db = -1;		/* DLP-Handle der offenen Datenbank */
static char open_db_name[34];

static const char base64_chars[] =
	"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* Schreibt den Wert eines JSON-Felds als Base64 (ohne Zeilenumbrüche) */
static void emit_base64(const char *key, const unsigned char *data, size_t len)
{
	size_t i;

	printf(",\"%s\":\"", key);
	for (i = 0; i + 2 < len; i += 3) {
		unsigned int v = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
		putchar(base64_chars[(v >> 18) & 63]);
		putchar(base64_chars[(v >> 12) & 63]);
		putchar(base64_chars[(v >> 6) & 63]);
		putchar(base64_chars[v & 63]);
	}
	if (i < len) {
		unsigned int v = data[i] << 16;
		if (i + 1 < len)
			v |= data[i + 1] << 8;
		putchar(base64_chars[(v >> 18) & 63]);
		putchar(base64_chars[(v >> 12) & 63]);
		putchar(i + 1 < len ? base64_chars[(v >> 6) & 63] : '=');
		putchar('=');
	}
	putchar('"');
}

/* Base64 nach <out>; -1, wenn der Text kein Base64 ist oder nicht passt */
static long decode_base64(const char *in, unsigned char *out, size_t out_size)
{
	unsigned int v = 0;
	int bits = 0;
	size_t n = 0;

	for (; *in && *in != '='; in++) {
		const char *p = strchr(base64_chars, *in);

		if (p == NULL || *in == '\0')
			return -1;
		v = (v << 6) | (unsigned int)(p - base64_chars);
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			if (n >= out_size)
				return -1;
			out[n++] = (unsigned char)((v >> bits) & 0xFF);
		}
	}
	return (long)n;
}

/* Fehler eines DLP-Aufrufs mit den Rohcodes, wie bei backupFailed */
static void emit_dlp_error(int sd, const char *stage, const char *what)
{
	emit_begin("error");
	emit_str("stage", stage, 0);
	emit_str("message", what, 0);
	emit_int("error", pi_error(sd));
	emit_int("palmOSError", pi_palmos_error(sd));
	emit_end();
}

static int require_open_db(const char *stage)
{
	if (open_db < 0) {
		emit_error(stage, "no database open (opendb first)");
		return 0;
	}
	return 1;
}

/* "opendb <r|rw> <Name>": geheime Datensätze immer mit, sonst fehlen sie
 * im Abgleich und würden beim nächsten Schreiben verloren gehen. */
static void open_database(int sd, const char *args)
{
	int mode;
	const char *name;
	int records = 0;

	if (strncmp(args, "r ", 2) == 0) {
		mode = dlpOpenRead | dlpOpenSecret;
		name = args + 2;
	} else if (strncmp(args, "rw ", 3) == 0) {
		mode = dlpOpenReadWrite | dlpOpenSecret;
		name = args + 3;
	} else {
		emit_error("opendb", "usage: opendb <r|rw> <name>");
		return;
	}
	if (open_db >= 0) {
		dlp_CloseDB(sd, open_db);
		open_db = -1;
	}
	utf8_to_cp1252(name, open_db_name, sizeof(open_db_name));
	if (dlp_OpenDB(sd, 0, mode, open_db_name, &open_db) < 0) {
		open_db = -1;
		emit_dlp_error(sd, "opendb", "cannot open the database");
		return;
	}
	if (dlp_ReadOpenDBInfo(sd, open_db, &records) < 0)
		records = -1;

	emit_begin("dbOpened");
	emit_str("name", open_db_name, 1);
	emit_int("records", records);
	emit_end();
}

static void close_database(int sd)
{
	if (!require_open_db("closedb"))
		return;
	/* entweder Fehler oder dbClosed, nie beides: die App geht bei jedem weiter */
	if (dlp_CloseDB(sd, open_db) < 0) {
		emit_dlp_error(sd, "closedb", "cannot close the database");
		open_db = -1;
		return;
	}
	open_db = -1;
	emit_begin("dbClosed");
	emit_end();
}

static void read_app_info(int sd)
{
	pi_buffer_t *buf;

	if (!require_open_db("readappinfo"))
		return;
	buf = pi_buffer_new(0xFFFF);
	if (dlp_ReadAppBlock(sd, open_db, 0, DLP_BUF_SIZE, buf) < 0) {
		emit_dlp_error(sd, "readappinfo", "cannot read the AppInfo block");
	} else {
		emit_begin("appInfo");
		emit_base64("data", buf->data, buf->used);
		emit_end();
	}
	pi_buffer_free(buf);
}

static void write_app_info(int sd, const char *args)
{
	unsigned char data[0xFFFF];
	long len = decode_base64(args, data, sizeof(data));

	if (!require_open_db("writeappinfo"))
		return;
	if (len < 0) {
		emit_error("writeappinfo", "usage: writeappinfo <base64>");
		return;
	}
	if (dlp_WriteAppBlock(sd, open_db, data, (size_t)len) < 0) {
		emit_dlp_error(sd, "writeappinfo", "cannot write the AppInfo block");
		return;
	}
	emit_begin("appInfoWritten");
	emit_int("bytes", len);
	emit_end();
}

static void emit_record(recordid_t id, int index, int attrs, int category, const pi_buffer_t *buf)
{
	emit_begin("record");
	emit_int("id", (long)id);
	emit_int("index", index);
	/* alle Marken, auch "archiviert" (0x08): auf dem Draht sind Marken und
	 * Kategorie getrennt, anders als in der Datei */
	emit_int("attrs", attrs & 0xF8);
	emit_int("category", category & 0x0F);
	emit_base64("data", buf->data, buf->used);
	emit_end();
}

/* "readall": jeden Datensatz nach Index - der langsame Abgleich, wenn die
 * Änderungsmarken nichts taugen. "readmodified": nur die seit dem letzten
 * Abgleich geänderten (auch gelöschte, dann ohne Daten). Zum Schluss
 * recordsDone mit der Anzahl. */
static void read_records(int sd, int modified_only)
{
	const char *stage = modified_only ? "readmodified" : "readall";
	pi_buffer_t *buf;
	int count = 0, total = 0, index;
	recordid_t id;
	int attrs, category;

	if (!require_open_db(stage))
		return;
	buf = pi_buffer_new(0xFFFF);

	if (modified_only) {
		for (;;) {
			int result = dlp_ReadNextModifiedRec(sd, open_db, buf, &id, &index, &attrs, &category);

			if (result < 0) {
				/* das Ende meldet der Palm als "nicht gefunden" */
				if (!(pi_error(sd) == PI_ERR_DLP_PALMOS && pi_palmos_error(sd) == dlpErrNotFound)) {
					emit_dlp_error(sd, stage, "cannot read the next modified record");
					pi_buffer_free(buf);
					return;
				}
				break;
			}
			emit_record(id, index, attrs, category, buf);
			count++;
			if (!pi_socket_connected(sd)) {
				emit_error(stage, "connection lost while reading records");
				pi_buffer_free(buf);
				return;
			}
		}
	} else {
		if (dlp_ReadOpenDBInfo(sd, open_db, &total) < 0) {
			emit_dlp_error(sd, stage, "cannot count the records");
			pi_buffer_free(buf);
			return;
		}
		for (index = 0; index < total; index++) {
			if (dlp_ReadRecordByIndex(sd, open_db, index, buf, &id, &attrs, &category) < 0) {
				emit_dlp_error(sd, stage, "cannot read a record");
				pi_buffer_free(buf);
				return;
			}
			emit_record(id, index, attrs, category, buf);
			count++;
			if (!pi_socket_connected(sd)) {
				emit_error(stage, "connection lost while reading records");
				pi_buffer_free(buf);
				return;
			}
		}
	}
	pi_buffer_free(buf);

	emit_begin("recordsDone");
	emit_int("count", count);
	emit_int("modifiedOnly", modified_only);
	emit_end();
}

static void read_record(int sd, const char *args)
{
	char *end;
	unsigned long id = strtoul(args, &end, 10);
	pi_buffer_t *buf;
	int index, attrs, category;

	if (!require_open_db("readrec"))
		return;
	if (end == args) {
		emit_error("readrec", "usage: readrec <id>");
		return;
	}
	buf = pi_buffer_new(0xFFFF);
	if (dlp_ReadRecordById(sd, open_db, (recordid_t)id, buf, &index, &attrs, &category) < 0)
		emit_dlp_error(sd, "readrec", "cannot read the record");
	else
		emit_record((recordid_t)id, index, attrs, category, buf);
	pi_buffer_free(buf);
}

/* "writerec <ID> <Attr> <Kategorie> <Base64>": ID 0 lässt den Palm eine
 * vergeben; die vergebene kommt in recordWritten zurück. */
static void write_record(int sd, const char *args)
{
	char *end;
	unsigned long id, attrs, category;
	unsigned char data[0xFFFF];
	long len;
	recordid_t new_id = 0;

	if (!require_open_db("writerec"))
		return;
	id = strtoul(args, &end, 10);
	if (end == args || *end != ' ')
		goto usage;
	attrs = strtoul(end + 1, &end, 10);
	if (*end != ' ')
		goto usage;
	category = strtoul(end + 1, &end, 10);
	if (*end != ' ')
		goto usage;
	len = decode_base64(end + 1, data, sizeof(data));
	if (len < 0)
		goto usage;

	if (dlp_WriteRecord(sd, open_db, (int)(attrs & 0xF8), (recordid_t)id, (int)(category & 0x0F),
			    data, (size_t)len, &new_id) < 0) {
		emit_dlp_error(sd, "writerec", "cannot write the record");
		return;
	}
	emit_begin("recordWritten");
	emit_int("id", (long)new_id);
	emit_int("bytes", len);
	emit_end();
	return;

usage:
	emit_error("writerec", "usage: writerec <id> <attrs> <category> <base64>");
}

static void delete_record(int sd, const char *args)
{
	char *end;
	unsigned long id = strtoul(args, &end, 10);

	if (!require_open_db("deleterec"))
		return;
	if (end == args || id == 0) {
		emit_error("deleterec", "usage: deleterec <id>");
		return;
	}
	if (dlp_DeleteRecord(sd, open_db, 0, (recordid_t)id) < 0) {
		emit_dlp_error(sd, "deleterec", "cannot delete the record");
		return;
	}
	emit_begin("recordDeleted");
	emit_int("id", (long)id);
	emit_end();
}

/* Löscht eine Datenbank auf dem Palm (Karte 0). Für Aufräumarbeiten, etwa
 * eine Garnet-PIM-Datenbank, die versehentlich auf einen Cobalt kam. */
static void delete_database(int sd, const char *name)
{
	if (*name == '\0') {
		emit_error("deletedb", "usage: deletedb <name>");
		return;
	}
	if (dlp_DeleteDB(sd, 0, name) < 0) {
		emit_dlp_error(sd, "deletedb", "cannot delete the database");
		return;
	}
	emit_begin("databaseDeleted");
	emit_str("name", name, 1);
	emit_end();
}

static void reset_flags(int sd)
{
	if (!require_open_db("resetflags"))
		return;
	if (dlp_ResetSyncFlags(sd, open_db) < 0) {
		emit_dlp_error(sd, "resetflags", "cannot reset the sync flags");
		return;
	}
	emit_begin("flagsReset");
	emit_end();
}

static void clean_up(int sd)
{
	if (!require_open_db("cleanup"))
		return;
	if (dlp_CleanUpDatabase(sd, open_db) < 0) {
		emit_dlp_error(sd, "cleanup", "cannot clean up the database");
		return;
	}
	emit_begin("cleanedUp");
	emit_end();
}

/* "syncinfo <PC-ID>": merkt im Palm, welcher PC jetzt abgeglichen hat, und
 * die Zeit - die Grundlage für den schnellen Abgleich beim nächsten Mal. */
static void write_sync_info(int sd, const char *args)
{
	char *end;
	unsigned long pc = strtoul(args, &end, 10);
	struct PilotUser user = palm_user;
	time_t now = time(NULL);

	if (end == args || pc == 0) {
		emit_error("syncinfo", "usage: syncinfo <pc-id>");
		return;
	}
	user.lastSyncPC = pc;
	user.lastSyncDate = now;
	user.successfulSyncDate = now;
	if (dlp_WriteUserInfo(sd, &user) < 0) {
		emit_dlp_error(sd, "syncinfo", "cannot write the sync info");
		return;
	}
	palm_user = user;
	emit_begin("syncInfoWritten");
	emit_int("pcId", (long)pc);
	emit_int("date", (long)now);
	emit_end();
}

/* "settime [JAHRE]": die Uhr des Palms auf die Ortszeit des Macs stellen,
 * wie es der HotSync-Manager tat; libpisock rechnet time_t in die lokale
 * Zeit um. JAHRE: um so viele Jahre zurück, für einen Palm mit DateFix -
 * als Wanduhrzeit: derselbe Tag und dieselbe Uhrzeit wie jetzt, nur das
 * Jahr anders. (Den Zeitpunkt selbst zurückzurechnen gäbe eine andere
 * Stunde, wenn damals andere Sommerzeitregeln galten.) */
static void set_time(int sd, long years_back)
{
	time_t now = time(NULL);

	if (years_back > 0) {
		struct tm local = *localtime(&now);
		local.tm_year -= (int)years_back;
		local.tm_isdst = -1;
		now = mktime(&local);
	}
	if (dlp_SetSysDateTime(sd, now) < 0) {
		emit_dlp_error(sd, "settime", "cannot set the clock");
		return;
	}
	emit_begin("timeSet");
	emit_int("date", (long)now);
	emit_end();
}

/* "netsync ADRESSE MASKE NAME": diesen Mac als primären PC für den
 * Netzwerk-HotSync in den Palm schreiben, wie es der HotSync-Manager bei
 * jedem lokalen HotSync tat. Das LANSync-Flag bleibt, wie es war. */
static void write_net_sync(int sd, const char *args)
{
	struct NetSyncInfo info;
	char address[40], mask[40];
	const char *p = args, *q;

	memset(&info, 0, sizeof(info));
	if (dlp_ReadNetSyncInfo(sd, &info) < 0)
		memset(&info, 0, sizeof(info));

	q = strchr(p, ' ');
	if (!q) { emit_error("netsync", "usage: netsync ADDRESS MASK NAME"); return; }
	snprintf(address, sizeof(address), "%.*s", (int)(q - p), p);
	p = q + 1;
	q = strchr(p, ' ');
	if (!q) { emit_error("netsync", "usage: netsync ADDRESS MASK NAME"); return; }
	snprintf(mask, sizeof(mask), "%.*s", (int)(q - p), p);
	p = q + 1;

	strncpy(info.hostAddress, address, sizeof(info.hostAddress) - 1);
	strncpy(info.hostSubnetMask, mask, sizeof(info.hostSubnetMask) - 1);
	utf8_to_cp1252(p, info.hostName, sizeof(info.hostName));
	if (dlp_WriteNetSyncInfo(sd, &info) < 0) {
		emit_dlp_error(sd, "netsync", "cannot write the network HotSync settings");
		return;
	}
	emit_begin("netSyncSet");
	emit_str("address", info.hostAddress, 0);
	emit_str("name", info.hostName, 1);
	emit_end();
}

/* Abstand der Lebenszeichen an den Palm, solange keine Anweisung kommt -
 * ohne sie bricht der Palm die Sitzung nach einer Weile ab. */
#define TICKLE_INTERVAL_MS	5000

/* Wartet, bis eine Anweisung lesbar ist, und hält den Palm solange mit
 * Lebenszeichen wach. 0, wenn der Palm nicht mehr antwortet. */
/* Rohe DLP-Anfrage für die Cobalt-Erweiterungen (Befehlswörter ab 0x70),
 * die pilot-link nicht kennt: "rawdlp HEX [N]" schickt die Bytes so, wie sie
 * stehen, und gibt N Antwortnachrichten (Vorgabe 1) als Hex zurück; N = 0
 * liest, bis eine Nachricht nur noch aus dem Kopf besteht (so endet der
 * Zeilenstrom 0xAE). Nur zum Erkunden; die App benutzt es nicht. */
static void raw_dlp(int sd, const char *args)
{
	static uint8_t req[4096];
	const char *sp = strchr(args, ' ');
	size_t n = sp ? (size_t)(sp - args) : strlen(args);
	int count = sp ? atoi(sp + 1) : 1, i, limit;
	pi_buffer_t *buf;

	if (n == 0 || n % 2 || n / 2 > sizeof(req) || count < 0 || count > 64) {
		emit_error("rawdlp", "bad request");
		return;
	}
	if (sp) {
		char hex[2 * sizeof(req) + 1];
		memcpy(hex, args, n);
		hex[n] = '\0';
		if (!hex_decode(hex, req, n / 2)) {
			emit_error("rawdlp", "bad hex");
			return;
		}
	} else if (!hex_decode(args, req, n / 2)) {
		emit_error("rawdlp", "bad hex");
		return;
	}
	pi_flush(sd, PI_FLUSH_INPUT);
	if (pi_write(sd, req, n / 2) < (ssize_t)(n / 2)) {
		emit_error("rawdlp", "write failed (%d)", pi_error(sd));
		return;
	}
	buf = pi_buffer_new(65536);
	limit = count ? count : 64;
	for (i = 0; i < limit; i++) {
		ssize_t got;

		pi_buffer_clear(buf);
		got = pi_read(sd, buf, buf->allocated);
		if (got < 0) {
			emit_error("rawdlp", "read failed (%ld)", (long)got);
			break;
		}
		emit_begin("rawdlp");
		emit_int("part", i);
		emit_hex("reply", buf->data, buf->used);
		emit_end();
		if (count == 0 && buf->used <= 6)
			break;
	}
	pi_buffer_free(buf);
}

/* ------------------------------------------------------------------------
 * Cobalt DLP: die Palm-OS-6-Erweiterungen (Befehlswörter 0x70-0xB2), mit
 * denen Cobalt seine Schema-Datenbanken (Kalender, Kontakte, Aufgaben,
 * Memos) erreichbar macht. pilot-link kennt sie nicht; die Rahmen werden
 * hier selbst gebaut und mit pi_write/pi_read über den DLP-Socket
 * geschickt. Nur lesende Befehle (Schritt 2 von Planning/cobalt-pim.md).
 *
 * Request:  u16 BE (0x7000|cmd), argc u8, 00, ein Argument id 0x20
 * Reply:    u16 BE (0xF000|cmd), argc u8, 00, err u16 BE, Argument
 * Argument: tiny [id][len u8], short [0x80|id][00][len u16],
 *           long [0x40|id][00][len u32] (Bit 6, nicht 0xC0).
 * Alle Felder big-endian, Strings als u32 Länge (mit NUL) + Bytes.
 * ------------------------------------------------------------------------ */

#define COBALT_ARG_ID		0x20
#define COBALT_REPLY_MAX	(256 * 1024)
#define COBALT_NAME_MAX		64

/* Die DLP-Fehlernummern, die Cobalts DLServer aus seinen status_t macht;
 * ab 25 Cobalt-Zusätze (Namen nach dem jeweiligen Data-Manager-Fehler). */
static const char *cobalt_error_name(int err)
{
	switch (err) {
	case 1: return "system error";
	case 2: return "illegal request";
	case 3: return "out of memory";
	case 4: return "bad parameter";
	case 5: return "not found";
	case 6: return "no database open";
	case 7: return "already open";
	case 8: return "too many open";
	case 9: return "already exists";
	case 10: return "cannot open";
	case 11: return "record deleted";
	case 12: return "record busy";
	case 13: return "not supported";
	case 15: return "read-only";
	case 16: return "not enough space";
	case 17: return "limit exceeded";
	case 18: return "cancelled";
	case 21: return "argument size";
	case 23: return "decrypt failed";
	case 25: return "access denied (trust required)";
	case 26: return "not a schema database";
	case 27: return "not a secure database";
	case 28: return "not a record database";
	case 29: return "invalid table name";
	case 30: return "invalid column id";
	case 31: return "invalid property id";
	case 32: return "invalid category";
	case 33: return "invalid column type";
	case 34: return "invalid column spec";
	case 35: return "one or more failed";
	case 36: return "invalid schema definition";
	case 37: return "no data";
	case 38: return "table not empty";
	case 40: return "column id exists";
	case 41: return "category limit";
	case 42: return "built-in property";
	case 43: return "name exists";
	case 44: return "aborted";
	case 45: return "encryption failure";
	case 47: return "invalid id";
	case 48: return "invalid column name";
	case 49: return "invalid size spec";
	case 50: return "unknown handle";
	default: return "unknown error";
	}
}

/* Ein Fehler des Palm auf einen Cobalt-Befehl: das gewohnte error-Ereignis,
 * dazu Nummer und Name, damit die App 25 (Vertrauen nötig) oder 15
 * (schreibgeschützt) erkennen kann. */
static void emit_cobalt_error(const char *stage, int cmd, int err)
{
	emit_begin("error");
	emit_str("stage", stage, 0);
	printf(",\"message\":\"Cobalt command 0x%02X failed: %s (%d)\"", cmd, cobalt_error_name(err), err);
	emit_int("cmd", cmd);
	emit_int("code", err);
	emit_str("name", cobalt_error_name(err), 0);
	emit_end();
}

/* --- Bytes schreiben (Request) --- */

struct cobalt_req {
	uint8_t data[4096];
	size_t len;		/* Argumentbytes bisher (ohne Rahmen) */
	int overflow;
};

#define COBALT_REQ_HEAD 10	/* Platz für Rahmen und das längste Argumentkopf (6) */

static void req_init(struct cobalt_req *r)
{
	r->len = 0;
	r->overflow = 0;
}

static void req_bytes(struct cobalt_req *r, const void *bytes, size_t n)
{
	if (r->len + n > sizeof(r->data) - COBALT_REQ_HEAD) {
		r->overflow = 1;
		return;
	}
	memcpy(r->data + COBALT_REQ_HEAD + r->len, bytes, n);
	r->len += n;
}

static void req_u8(struct cobalt_req *r, unsigned v)
{
	uint8_t b = (uint8_t)v;
	req_bytes(r, &b, 1);
}

static void req_u16(struct cobalt_req *r, unsigned v)
{
	uint8_t b[2] = { (uint8_t)(v >> 8), (uint8_t)v };
	req_bytes(r, b, 2);
}

static void req_u32(struct cobalt_req *r, uint32_t v)
{
	uint8_t b[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
	req_bytes(r, b, 4);
}

/* Ein Name, wie Cobalt ihn erwartet: u32 Länge einschließlich NUL, dann
 * die Bytes mit NUL. */
static void req_string(struct cobalt_req *r, const char *s)
{
	size_t n = strlen(s) + 1;
	req_u32(r, (uint32_t)n);
	req_bytes(r, s, n);
}

/* Vier Zeichen (Typ, Creator) als u32. */
static uint32_t fourcc(const char *s)
{
	return (uint32_t)(uint8_t)s[0] << 24 | (uint32_t)(uint8_t)s[1] << 16
	    | (uint32_t)(uint8_t)s[2] << 8 | (uint32_t)(uint8_t)s[3];
}

/* --- Bytes lesen (Reply) --- */

struct cobalt_cur {
	const uint8_t *p;
	size_t left;
	int bad;	/* über das Ende gelesen: der Rest ist Unsinn */
};

static const uint8_t *cur_take(struct cobalt_cur *c, size_t n)
{
	static const uint8_t zeros[8];
	const uint8_t *p;

	if (c->bad || n > c->left) {
		c->bad = 1;
		c->left = 0;
		return n <= sizeof(zeros) ? zeros : NULL;
	}
	p = c->p;
	c->p += n;
	c->left -= n;
	return p;
}

static unsigned cur_u8(struct cobalt_cur *c)
{
	return cur_take(c, 1)[0];
}

static unsigned cur_u16(struct cobalt_cur *c)
{
	const uint8_t *p = cur_take(c, 2);
	return (unsigned)p[0] << 8 | p[1];
}

static uint32_t cur_u32(struct cobalt_cur *c)
{
	const uint8_t *p = cur_take(c, 4);
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

/* u32 Länge + Bytes; kopiert bis zur ersten NUL oder bis cap-1 in out. */
static void cur_string(struct cobalt_cur *c, char *out, size_t cap)
{
	uint32_t n = cur_u32(c);
	const uint8_t *p = (n > c->left) ? cur_take(c, c->left + 1) : cur_take(c, n);
	size_t i;

	out[0] = '\0';
	if (p == NULL || c->bad)
		return;
	for (i = 0; i < n && i + 1 < cap && p[i] != '\0'; i++)
		out[i] = (char)p[i];
	out[i] = '\0';
}

static void fourcc_string(uint32_t v, char out[5])
{
	int i;
	for (i = 0; i < 4; i++) {
		unsigned c = (v >> (24 - 8 * i)) & 0xFF;
		out[i] = (c >= 0x20 && c < 0x7F) ? (char)c : '?';
	}
	out[4] = '\0';
}

/* Eine Cobalt-Antwort: Fehler und das eine Argument. */
struct cobalt_reply {
	int err;
	int argc;
	const uint8_t *arg;
	size_t arglen;
};

/* Liest eine Antwortnachricht und zerlegt sie; -1, wenn der Transport
 * versagt oder die Antwort nicht zum Befehl passt (Ereignis ausgegeben).
 * Für Befehle, die mehrere Nachrichten schicken (0xAE: Daten, dann ein
 * leeres F0 AE), ist dies pro Nachricht einmal aufzurufen. */
static int cobalt_read_reply(int sd, const char *stage, int cmd, pi_buffer_t *buf, struct cobalt_reply *out)
{
	ssize_t got;
	unsigned word;
	const uint8_t *p;

	memset(out, 0, sizeof(*out));
	pi_buffer_clear(buf);
	got = pi_read(sd, buf, buf->allocated);
	if (got < 0) {
		emit_error(stage, "read failed (%ld)", (long)got);
		return -1;
	}
	if (buf->used < 6) {
		emit_error(stage, "short reply (%lu bytes)", (unsigned long)buf->used);
		return -1;
	}
	p = buf->data;
	word = (unsigned)p[0] << 8 | p[1];
	if (word != (0xF000u | (unsigned)cmd)) {
		emit_error(stage, "reply %04x does not match command 0x%02X", word, cmd);
		return -1;
	}
	out->argc = p[2];
	out->err = (int)((unsigned)p[4] << 8 | p[5]);
	if (out->argc == 0 || buf->used == 6)
		return 0;
	p += 6;
	{
		size_t rest = buf->used - 6, head, len;
		unsigned id = p[0];

		if (id & 0x40) {
			if (rest < 6)
				goto truncated;
			head = 6;
			len = (size_t)p[2] << 24 | (size_t)p[3] << 16 | (size_t)p[4] << 8 | p[5];
		} else if (id & 0x80) {
			if (rest < 4)
				goto truncated;
			head = 4;
			len = (size_t)p[2] << 8 | p[3];
		} else {
			if (rest < 2)
				goto truncated;
			head = 2;
			len = p[1];
		}
		if (len > rest - head)
			goto truncated;
		out->arg = p + head;
		out->arglen = len;
	}
	return 0;
truncated:
	emit_error(stage, "truncated reply argument");
	return -1;
}

/* Schickt einen Cobalt-Befehl mit dem Argument in r und liest die Antwort.
 * 0 bei Erfolg (Antwortargument in rp), 1 bei einem Fehler des Palm
 * (Ereignis ausgegeben, rp->err gesetzt), -1 bei Transportfehlern. */
static int cobalt_exec(int sd, const char *stage, int cmd, struct cobalt_req *r, pi_buffer_t *buf, struct cobalt_reply *rp)
{
	uint8_t *start;
	size_t head, total;

	if (r->overflow) {
		emit_error(stage, "request too long");
		return -1;
	}
	/* Argumentkopf direkt vor den Argumentbytes, der Rahmen davor */
	if (r->len < 256)
		head = 2;
	else if (r->len <= 0xFFFF)
		head = 4;
	else
		head = 6;
	start = r->data + COBALT_REQ_HEAD - head - 4;
	start[0] = 0x70;
	start[1] = (uint8_t)cmd;
	start[2] = 1;
	start[3] = 0;
	if (head == 2) {
		start[4] = COBALT_ARG_ID;
		start[5] = (uint8_t)r->len;
	} else if (head == 4) {
		start[4] = 0x80 | COBALT_ARG_ID;
		start[5] = 0;
		start[6] = (uint8_t)(r->len >> 8);
		start[7] = (uint8_t)r->len;
	} else {
		start[4] = 0x40 | COBALT_ARG_ID;
		start[5] = 0;
		start[6] = (uint8_t)(r->len >> 24);
		start[7] = (uint8_t)(r->len >> 16);
		start[8] = (uint8_t)(r->len >> 8);
		start[9] = (uint8_t)r->len;
	}
	total = 4 + head + r->len;
	pi_flush(sd, PI_FLUSH_INPUT);
	if (pi_write(sd, start, total) < (ssize_t)total) {
		emit_error(stage, "write failed (%d)", pi_error(sd));
		return -1;
	}
	if (cobalt_read_reply(sd, stage, cmd, buf, rp) < 0)
		return -1;
	if (rp->err != 0) {
		emit_cobalt_error(stage, cmd, rp->err);
		return 1;
	}
	return 0;
}

/* Offene Schema-Datenbanken dieser Sitzung, nach dem Handle-Byte des Palm
 * (ab 1). Nur zur Beschriftung der Ereignisse; der Palm führt das Buch. */
static char cobalt_open_names[256][COBALT_NAME_MAX];

static const char *cobalt_handle_name(unsigned handle)
{
	return cobalt_open_names[handle & 0xFF];
}

/* Datum aus der Liste: u16 Jahr, Monat, Tag, Stunde, Minute, Sekunde, 00.
 * Jahr 0 = nicht gesetzt (die anderen Bytes sind dann Zufall). */
static void emit_cobalt_date(const char *key, struct cobalt_cur *c)
{
	const uint8_t *p = cur_take(c, 8);
	unsigned year = (unsigned)p[0] << 8 | p[1];
	char text[32];

	if (year == 0)
		return;
	snprintf(text, sizeof(text), "%04u-%02u-%02u %02u:%02u:%02u", year, p[2], p[3], p[4], p[5], p[6]);
	emit_str(key, text, 0);
}

/* "cobaltlist": 0x7F mit Flags 0x0007 (Schema-Datenbanken, ROM und RAM).
 * Ein cobaltDatabase pro Datenbank, dann cobaltListDone mit der Anzahl.
 * Attribut 0x1000 = Schema, 0x2000 = gesichert (Vertrauen nötig). */
static void cobalt_list(int sd)
{
	struct cobalt_req r;
	struct cobalt_reply rp;
	struct cobalt_cur c;
	pi_buffer_t *buf = pi_buffer_new(COBALT_REPLY_MAX);
	uint32_t count, i;

	req_init(&r);
	req_u16(&r, 0x0007);
	if (cobalt_exec(sd, "cobaltlist", 0x7F, &r, buf, &rp) == 0) {
		c.p = rp.arg;
		c.left = rp.arglen;
		c.bad = 0;
		count = cur_u32(&c);
		for (i = 0; i < count && !c.bad; i++) {
			char type[5], creator[5], name[COBALT_NAME_MAX];
			unsigned marker = cur_u8(&c), attr, misc, version;
			uint32_t modnum;

			if (marker != 0x80) {
				emit_error("cobaltlist", "record %u has marker 0x%02x", (unsigned)i, marker);
				break;
			}
			fourcc_string(cur_u32(&c), type);
			fourcc_string(cur_u32(&c), creator);
			attr = cur_u16(&c);
			misc = cur_u16(&c);
			version = cur_u16(&c);
			emit_begin("cobaltDatabase");
			emit_int("index", (long)i);
			emit_cobalt_date("created", &c);
			emit_cobalt_date("modified", &c);
			emit_cobalt_date("backedUp", &c);
			modnum = cur_u32(&c);
			cur_string(&c, name, sizeof(name));
			cur_u8(&c);	/* abschließendes 00 */
			emit_str("name", name, 1);
			emit_str("type", type, 0);
			emit_str("creator", creator, 0);
			emit_int("attr", attr);
			emit_int("schema", (attr & 0x1000) != 0);
			emit_int("secure", (attr & 0x2000) != 0);
			emit_int("misc", misc);
			emit_int("version", version);
			emit_int("modnum", (long)modnum);
			emit_end();
		}
		if (c.bad)
			emit_error("cobaltlist", "list truncated after %u of %u databases", (unsigned)i, (unsigned)count);
		emit_begin("cobaltListDone");
		emit_int("count", (long)i);
		emit_end();
	}
	pi_buffer_free(buf);
}

/* "cobaltopen NAME CREATOR MODE [TOKENHEX]": 0x81. MODE 1 lesen, 2
 * schreiben, 3 beides. Das Token (10 Bytes vom letzten Schließen) geht
 * mit, wenn eines da ist. Antwort: cobaltOpened mit dem Handle. */
static void cobalt_open(int sd, const char *args)
{
	char name[COBALT_NAME_MAX], creator[8], token_hex[2 * 64 + 1];
	uint8_t token[64];
	size_t token_len = 0;
	int mode, n;
	struct cobalt_req r;
	struct cobalt_reply rp;
	pi_buffer_t *buf;

	token_hex[0] = '\0';
	n = sscanf(args, "%63s %7s %d %128s", name, creator, &mode, token_hex);
	if (n < 3 || strlen(creator) != 4 || mode < 1 || mode > 3 || strlen(name) > 31) {
		emit_error("cobaltopen", "usage: cobaltopen NAME CREATOR MODE [TOKENHEX]");
		return;
	}
	if (n == 4) {
		size_t h = strlen(token_hex);
		if (h % 2 || h / 2 > sizeof(token) || !hex_decode(token_hex, token, h / 2)) {
			emit_error("cobaltopen", "bad token hex");
			return;
		}
		token_len = h / 2;
	}
	req_init(&r);
	req_u32(&r, fourcc(creator));
	req_u32(&r, (uint32_t)token_len);
	req_u16(&r, (unsigned)mode);
	req_u16(&r, 0);		/* share */
	req_string(&r, name);
	req_bytes(&r, token, token_len);
	buf = pi_buffer_new(COBALT_REPLY_MAX);
	if (cobalt_exec(sd, "cobaltopen", 0x81, &r, buf, &rp) == 0) {
		if (rp.arglen < 1) {
			emit_error("cobaltopen", "no handle in the reply");
		} else {
			unsigned handle = rp.arg[0];
			snprintf(cobalt_open_names[handle], COBALT_NAME_MAX, "%s", name);
			emit_begin("cobaltOpened");
			emit_int("handle", handle);
			emit_str("name", name, 1);
			emit_str("creator", creator, 0);
			emit_int("mode", mode);
			emit_end();
		}
	}
	pi_buffer_free(buf);
}

/* "cobaltclose HANDLE [FLAGS]": 0x82. FLAGS 0x80 Sicherungsdatum setzen,
 * 0x40 Änderungsdatum setzen, 0x20 Sync-Token zurückgeben (nach einem
 * Öffnen mit Modus 1 antwortet der Palm darauf mit 15; nach einem
 * lesenden Öffnen also mit 0 schließen). cobaltClosed trägt das Token als
 * Hex, wenn eines kam. */
static void cobalt_close(int sd, const char *args)
{
	int handle, flags = 0, n;
	struct cobalt_req r;
	struct cobalt_reply rp;
	pi_buffer_t *buf;

	n = sscanf(args, "%i %i", &handle, &flags);
	if (n < 1 || handle < 1 || handle > 255 || flags < 0 || flags > 255) {
		emit_error("cobaltclose", "usage: cobaltclose HANDLE [FLAGS]");
		return;
	}
	req_init(&r);
	req_u8(&r, (unsigned)handle);
	req_u8(&r, (unsigned)flags);
	buf = pi_buffer_new(COBALT_REPLY_MAX);
	if (cobalt_exec(sd, "cobaltclose", 0x82, &r, buf, &rp) == 0) {
		struct cobalt_cur c = { rp.arg, rp.arglen, 0 };
		uint32_t len = cur_u32(&c);
		const uint8_t *token = len <= c.left ? cur_take(&c, len) : NULL;

		emit_begin("cobaltClosed");
		emit_int("handle", handle);
		emit_str("name", cobalt_handle_name((unsigned)handle), 1);
		if (token != NULL && len > 0)
			emit_hex("token", token, len);
		emit_end();
		cobalt_open_names[handle][0] = '\0';
	}
	pi_buffer_free(buf);
}

/* Gemeinsamer Anfang der Befehle mit "HANDLE [TABLE]": prüft das Handle,
 * baut das Argument mit Handle (und ggf. Tabellenname) auf. 0 bei Unsinn. */
static int cobalt_handle_args(const char *stage, const char *args, int want_table, int *handle, char *table, size_t cap)
{
	char fmt[32];
	int n;

	table[0] = '\0';
	snprintf(fmt, sizeof(fmt), "%%i %%%lus", (unsigned long)(cap - 1));
	n = sscanf(args, fmt, handle, table);
	if (n < 1 + want_table || *handle < 1 || *handle > 255 || (want_table && strlen(table) > 31)) {
		emit_error(stage, want_table ? "usage: %s HANDLE TABLE" : "usage: %s HANDLE", stage);
		return 0;
	}
	return 1;
}

/* "cobalttables HANDLE": 0x71, ein cobaltTable pro Tabelle (Name, Spalten),
 * dann cobaltTablesDone. */
static void cobalt_tables(int sd, const char *args)
{
	int handle;
	char table[COBALT_NAME_MAX];
	struct cobalt_req r;
	struct cobalt_reply rp;
	pi_buffer_t *buf;

	if (!cobalt_handle_args("cobalttables", args, 0, &handle, table, sizeof(table)))
		return;
	req_init(&r);
	req_u8(&r, (unsigned)handle);
	buf = pi_buffer_new(COBALT_REPLY_MAX);
	if (cobalt_exec(sd, "cobalttables", 0x71, &r, buf, &rp) == 0) {
		struct cobalt_cur c = { rp.arg, rp.arglen, 0 };
		uint32_t count = cur_u32(&c), i;

		for (i = 0; i < count && !c.bad; i++) {
			uint32_t columns = cur_u32(&c);
			cur_string(&c, table, sizeof(table));
			if (c.bad)
				break;
			emit_begin("cobaltTable");
			emit_int("handle", handle);
			emit_str("name", table, 1);
			emit_int("columns", (long)columns);
			emit_end();
		}
		if (c.bad)
			emit_error("cobalttables", "table list truncated");
		emit_begin("cobaltTablesDone");
		emit_int("handle", handle);
		emit_int("count", (long)i);
		emit_end();
	}
	pi_buffer_free(buf);
}

/* "cobaltschema HANDLE TABLE": 0x76, ein cobaltColumn pro Spalte (id,
 * maxSize, type, attrib, name, err), dann cobaltSchemaDone. Typen wie im
 * SDK: 0x10 VarChar, 0x0B Boolean, 0x12 DateTimeSecs, 0x0D Date, 0x05
 * UInt8, 0x02 UInt16; Bit 7 = Vektor davon. */
static void cobalt_schema(int sd, const char *args)
{
	int handle;
	char table[COBALT_NAME_MAX];
	struct cobalt_req r;
	struct cobalt_reply rp;
	pi_buffer_t *buf;

	if (!cobalt_handle_args("cobaltschema", args, 1, &handle, table, sizeof(table)))
		return;
	req_init(&r);
	req_u8(&r, (unsigned)handle);
	req_string(&r, table);
	buf = pi_buffer_new(COBALT_REPLY_MAX);
	if (cobalt_exec(sd, "cobaltschema", 0x76, &r, buf, &rp) == 0) {
		struct cobalt_cur c = { rp.arg, rp.arglen, 0 };
		uint32_t count = cur_u32(&c), i;

		for (i = 0; i < count && !c.bad; i++) {
			uint32_t id = cur_u32(&c), max_size = cur_u32(&c), err;
			unsigned type = cur_u8(&c), attrib = cur_u8(&c);
			char name[COBALT_NAME_MAX];

			cur_string(&c, name, sizeof(name));
			err = cur_u32(&c);
			if (c.bad)
				break;
			emit_begin("cobaltColumn");
			emit_int("handle", handle);
			emit_str("table", table, 1);
			emit_int("id", (long)id);
			emit_str("name", name, 1);
			emit_int("type", type);
			emit_int("attrib", attrib);
			emit_int("maxSize", (long)max_size);
			emit_int("err", (long)err);
			emit_end();
		}
		if (c.bad)
			emit_error("cobaltschema", "column list truncated");
		emit_begin("cobaltSchemaDone");
		emit_int("handle", handle);
		emit_str("table", table, 1);
		emit_int("count", (long)i);
		emit_end();
	}
	pi_buffer_free(buf);
}

/* "cobaltcategories HANDLE": 0x98, ein cobaltCategory pro Kategorie (id,
 * name), dann cobaltCategoriesDone. "Unfiled" (0) steht nicht in der
 * Liste; es ist die stille Vorgabe. */
static void cobalt_categories(int sd, const char *args)
{
	int handle;
	char name[COBALT_NAME_MAX];
	struct cobalt_req r;
	struct cobalt_reply rp;
	pi_buffer_t *buf;

	if (!cobalt_handle_args("cobaltcategories", args, 0, &handle, name, sizeof(name)))
		return;
	req_init(&r);
	req_u8(&r, (unsigned)handle);
	buf = pi_buffer_new(COBALT_REPLY_MAX);
	if (cobalt_exec(sd, "cobaltcategories", 0x98, &r, buf, &rp) == 0) {
		struct cobalt_cur c = { rp.arg, rp.arglen, 0 };
		uint32_t count = cur_u32(&c), i;

		for (i = 0; i < count && !c.bad; i++) {
			uint32_t id = cur_u32(&c);
			cur_string(&c, name, sizeof(name));
			if (c.bad)
				break;
			emit_begin("cobaltCategory");
			emit_int("handle", handle);
			emit_int("id", (long)id);
			emit_str("name", name, 1);
			emit_end();
		}
		if (c.bad)
			emit_error("cobaltcategories", "category list truncated");
		emit_begin("cobaltCategoriesDone");
		emit_int("handle", handle);
		emit_int("count", (long)i);
		emit_end();
	}
	pi_buffer_free(buf);
}

/* "cobaltsyncstate HANDLE": 0x87 ohne Token (nur lesen). cobaltSyncState
 * mit format, syncId, clock und den drei Purge-Zählern; syncable 0, wenn
 * die Datenbank keinen Sync-Zustand führt (Länge 0). */
static void cobalt_sync_state(int sd, const char *args)
{
	int handle;
	char unused[COBALT_NAME_MAX];
	struct cobalt_req r;
	struct cobalt_reply rp;
	pi_buffer_t *buf;

	if (!cobalt_handle_args("cobaltsyncstate", args, 0, &handle, unused, sizeof(unused)))
		return;
	req_init(&r);
	req_u8(&r, (unsigned)handle);
	req_u32(&r, 0);		/* kein Token */
	buf = pi_buffer_new(COBALT_REPLY_MAX);
	if (cobalt_exec(sd, "cobaltsyncstate", 0x87, &r, buf, &rp) == 0) {
		struct cobalt_cur c = { rp.arg, rp.arglen, 0 };
		uint32_t len = cur_u32(&c);

		emit_begin("cobaltSyncState");
		emit_int("handle", handle);
		if (len >= 16) {
			uint32_t format = cur_u32(&c), sync_id = cur_u32(&c);
			unsigned clock = cur_u16(&c), rows = cur_u16(&c), schemas = cur_u16(&c), cats = cur_u16(&c);

			emit_int("syncable", !c.bad);
			if (!c.bad) {
				emit_int("format", (long)format);
				emit_int("syncId", (long)sync_id);
				emit_int("clock", clock);
				emit_int("rowsPurge", rows);
				emit_int("schemasPurge", schemas);
				emit_int("categoryPurge", cats);
			}
		} else {
			emit_int("syncable", 0);
		}
		emit_end();
	}
	pi_buffer_free(buf);
}

/* "cobaltrowcount HANDLE TABLE": 0x88 mit Flag 0 (gelöschte Zeilen
 * mitgezählt). cobaltRowCount mit rows. */
static void cobalt_row_count(int sd, const char *args)
{
	int handle;
	char table[COBALT_NAME_MAX];
	struct cobalt_req r;
	struct cobalt_reply rp;
	pi_buffer_t *buf;

	if (!cobalt_handle_args("cobaltrowcount", args, 1, &handle, table, sizeof(table)))
		return;
	req_init(&r);
	req_u8(&r, (unsigned)handle);
	req_u8(&r, 0);
	req_string(&r, table);
	buf = pi_buffer_new(COBALT_REPLY_MAX);
	if (cobalt_exec(sd, "cobaltrowcount", 0x88, &r, buf, &rp) == 0) {
		struct cobalt_cur c = { rp.arg, rp.arglen, 0 };
		uint32_t rows = cur_u32(&c);

		if (c.bad) {
			emit_error("cobaltrowcount", "short reply");
		} else {
			emit_begin("cobaltRowCount");
			emit_int("handle", handle);
			emit_str("table", table, 1);
			emit_int("rows", (long)rows);
			emit_end();
		}
	}
	pi_buffer_free(buf);
}

/* ------------------------------------------------------------------------
 * 0xAE: Zeilen einer Schema-Datenbank lesen (Schritt 3 von
 * Planning/cobalt-pim.md). Ein Request, ein Datenstrom als Antwort:
 *
 *   u8 1, u32 X                 X = 0: alles in dieser Nachricht; sonst
 *                               (0x8000 gesehen) folgt mehr, Rahmen unbekannt
 *   je Zeile: 40 Bytes Kopf     u32 presentFlags, u32 err, u32 rowID,
 *                               u16 rowAttr, u32 tableIndex, u16 syncStatus,
 *                               u32 numCats, u32 8, u32 numCols, u32 catBytes,
 *                               4 Bytes, die der Palm nicht beschreibt
 *             numCats x u32     Kategorien
 *             numCols x 16      u32 colID, u32 size, u32 offset, u32 err
 *             Spaltenbytes      hintereinander, offset zeigt hinein; roh
 *                               (little-endian ARM), hier nicht gedeutet
 *   nTables x 32 Bytes          Tabellennamen (bis zur NUL, Rest Zufall)
 *   u32 rowCount, u32 nTables   Abschluss; ohne Zeilen fehlt die Namenstafel
 *
 * Danach schickt der Palm in derselben Transaktion eine leere F0-AE-
 * Nachricht (argc 0, err 0); sie wird nach dem Zerlegen abgeholt.
 * rowAttr: 0x80 gelöscht (Zeile ohne Spalten), 0x01 archiviert, 0x02
 * schreibgeschützt, 0x10 geheim. syncStatus: Bits 0/1 geändert seit der
 * Sync-Uhr, 4 gelöscht, 8 archiviert.
 * ------------------------------------------------------------------------ */

#define COBALT_ROW_FIELDS	0x0B	/* Zeileninfo, Kategorien, alle Spalten */
#define COBALT_ROW_HEADER	40
#define COBALT_TABLE_ENTRY	32
#define COBALT_READROWS_MAX	512

/* Zerlegt das Argument einer 0xAE-Antwort und gibt je Zeile ein
 * cobaltRow aus. 0 und die Zählwerte bei Erfolg, -1 nach einem
 * error-Ereignis (Strom zu kurz, X != 0, Index ohne Tabelle). fallback
 * ist der Tabellenname aus dem Befehl, falls der Palm keinen Index
 * liefert (selector 0 für eine unbekannte Zeile). */
static int cobalt_parse_rows(const char *stage, int handle, const char *fallback,
			     const uint8_t *arg, size_t arglen, uint32_t *rows_out, uint32_t *tables_out)
{
	struct cobalt_cur c;
	const uint8_t *names;
	uint32_t x, row_count, n_tables, rows = 0;
	size_t names_len;

	if (arglen < 13) {
		emit_error(stage, "short 0xAE reply (%lu bytes)", (unsigned long)arglen);
		return -1;
	}
	if (arg[0] != 1) {
		emit_error(stage, "0xAE reply starts with 0x%02x, not 1", arg[0]);
		return -1;
	}
	x = (uint32_t)arg[1] << 24 | (uint32_t)arg[2] << 16 | (uint32_t)arg[3] << 8 | arg[4];
	if (x != 0) {
		/* Mehr als eine Nachricht: wie die Fortsetzung gerahmt ist, hat
		 * noch kein Gerät gezeigt (Planning/cobalt-pim.md, Frage 2).
		 * Ausweg: cobaltreadrows mit Zeilen-IDs in kleinen Gruppen. */
		emit_error(stage, "0xAE result does not fit one message (X=0x%08lx); use cobaltreadrows in smaller groups",
			   (unsigned long)x);
		return -1;
	}
	/* Abschluss zuerst: er sagt, wo die Namenstafel beginnt */
	c.p = arg + arglen - 8;
	c.left = 8;
	c.bad = 0;
	row_count = cur_u32(&c);
	n_tables = cur_u32(&c);
	names_len = (size_t)n_tables * COBALT_TABLE_ENTRY;
	if (n_tables > 0xFFFF || arglen - 13 < names_len) {
		emit_error(stage, "0xAE reply claims %lu tables in %lu bytes", (unsigned long)n_tables, (unsigned long)arglen);
		return -1;
	}
	names = arg + arglen - 8 - names_len;
	c.p = arg + 5;
	c.left = (size_t)(names - (arg + 5));
	c.bad = 0;

	while (c.left > 0) {
		const uint8_t *h = cur_take(&c, COBALT_ROW_HEADER);
		uint32_t present, err, row_id, table_index, num_cats, num_cols, i, data_len = 0;
		unsigned attr, status;
		const uint8_t *cats, *cols, *data;
		char table[COBALT_TABLE_ENTRY];

		if (c.bad || h == NULL)
			break;
		present = (uint32_t)h[0] << 24 | (uint32_t)h[1] << 16 | (uint32_t)h[2] << 8 | h[3];
		err = (uint32_t)h[4] << 24 | (uint32_t)h[5] << 16 | (uint32_t)h[6] << 8 | h[7];
		row_id = (uint32_t)h[8] << 24 | (uint32_t)h[9] << 16 | (uint32_t)h[10] << 8 | h[11];
		attr = (unsigned)h[12] << 8 | h[13];
		table_index = (uint32_t)h[14] << 24 | (uint32_t)h[15] << 16 | (uint32_t)h[16] << 8 | h[17];
		status = (unsigned)h[18] << 8 | h[19];
		num_cats = (uint32_t)h[20] << 24 | (uint32_t)h[21] << 16 | (uint32_t)h[22] << 8 | h[23];
		num_cols = (uint32_t)h[28] << 24 | (uint32_t)h[29] << 16 | (uint32_t)h[30] << 8 | h[31];
		/* h[24..27] ist immer 8, h[32..35] = 4 * numCats, h[36..39] Zufall */
		if (num_cats > c.left / 4 || num_cols > c.left / 16) {
			c.bad = 1;
			break;
		}
		cats = cur_take(&c, (size_t)num_cats * 4);
		cols = cur_take(&c, (size_t)num_cols * 16);
		if (c.bad)
			break;
		for (i = 0; i < num_cols; i++) {
			const uint8_t *e = cols + 16 * i;
			uint32_t size = (uint32_t)e[4] << 24 | (uint32_t)e[5] << 16 | (uint32_t)e[6] << 8 | e[7];
			uint32_t offset = (uint32_t)e[8] << 24 | (uint32_t)e[9] << 16 | (uint32_t)e[10] << 8 | e[11];
			if (size > c.left || offset > c.left - size) {
				c.bad = 1;
				break;
			}
			if (offset + size > data_len)
				data_len = offset + size;
		}
		if (c.bad)
			break;
		data = cur_take(&c, data_len);
		if (c.bad)
			break;

		if (table_index < n_tables) {
			const uint8_t *e = names + (size_t)table_index * COBALT_TABLE_ENTRY;
			size_t k;
			for (k = 0; k + 1 < COBALT_TABLE_ENTRY && e[k] != '\0'; k++)
				table[k] = (char)e[k];
			table[k] = '\0';
		} else {
			snprintf(table, sizeof(table), "%s", fallback);
		}

		emit_begin("cobaltRow");
		emit_int("handle", handle);
		emit_str("table", table, 1);
		emit_int("rowId", (long)row_id);
		emit_int("attr", (long)attr);
		emit_int("syncStatus", (long)status);
		emit_int("modified", (status & 3) != 0);
		emit_int("deleted", (attr & 0x80) != 0 || (status & 4) != 0);
		emit_int("archived", (attr & 0x01) != 0 || (status & 8) != 0);
		emit_int("present", (long)present);
		emit_int("err", (long)err);
		fputs(",\"categories\":[", stdout);
		for (i = 0; i < num_cats; i++) {
			const uint8_t *e = cats + 4 * i;
			printf("%s%lu", i ? "," : "",
			       (unsigned long)((uint32_t)e[0] << 24 | (uint32_t)e[1] << 16 | (uint32_t)e[2] << 8 | e[3]));
		}
		fputs("],\"columns\":[", stdout);
		for (i = 0; i < num_cols; i++) {
			const uint8_t *e = cols + 16 * i;
			uint32_t id = (uint32_t)e[0] << 24 | (uint32_t)e[1] << 16 | (uint32_t)e[2] << 8 | e[3];
			uint32_t size = (uint32_t)e[4] << 24 | (uint32_t)e[5] << 16 | (uint32_t)e[6] << 8 | e[7];
			uint32_t offset = (uint32_t)e[8] << 24 | (uint32_t)e[9] << 16 | (uint32_t)e[10] << 8 | e[11];
			uint32_t cerr = (uint32_t)e[12] << 24 | (uint32_t)e[13] << 16 | (uint32_t)e[14] << 8 | e[15];
			printf("%s{\"id\":%lu,\"size\":%lu,\"err\":%lu", i ? "," : "",
			       (unsigned long)id, (unsigned long)size, (unsigned long)cerr);
			emit_hex("hex", data + offset, size);
			putchar('}');
		}
		putchar(']');
		emit_end();
		rows++;
	}
	if (c.bad) {
		emit_error(stage, "0xAE row stream truncated after %lu of %lu rows", (unsigned long)rows, (unsigned long)row_count);
		return -1;
	}
	if (rows != row_count)
		emit_error(stage, "0xAE reply counts %lu rows but carried %lu", (unsigned long)row_count, (unsigned long)rows);
	*rows_out = rows;
	*tables_out = n_tables;
	return 0;
}

/* Holt die leere zweite F0-AE-Nachricht ab, die jeden 0xAE-Strom
 * abschließt. 0, wenn sie so aussah; sonst ist ein Ereignis draußen. */
static int cobalt_drain_rows_end(int sd, const char *stage)
{
	pi_buffer_t *buf = pi_buffer_new(64);
	struct cobalt_reply rp;
	int ok;

	ok = cobalt_read_reply(sd, stage, 0xAE, buf, &rp) == 0;
	if (ok && (rp.argc != 0 || rp.err != 0)) {
		emit_error(stage, "second 0xAE message is not empty (argc %d, err %d)", rp.argc, rp.err);
		ok = 0;
	}
	pi_buffer_free(buf);
	return ok ? 0 : -1;
}

/* Schickt den fertigen 0xAE-Request, zerlegt die Daten, holt die leere
 * Nachricht ab und meldet cobaltRowsDone. */
static void cobalt_read_rows_exec(int sd, const char *stage, int handle, const char *table, struct cobalt_req *r)
{
	struct cobalt_reply rp;
	pi_buffer_t *buf = pi_buffer_new(COBALT_REPLY_MAX);
	uint32_t rows = 0, tables = 0;
	int rc;

	rc = cobalt_exec(sd, stage, 0xAE, r, buf, &rp);
	if (rc == 0) {
		rc = cobalt_parse_rows(stage, handle, table, rp.arg, rp.arglen, &rows, &tables);
		/* die leere Nachricht gehört zur selben Transaktion: in jedem
		 * Fall abholen, sonst liest der nächste Befehl sie als Antwort */
		if (cobalt_drain_rows_end(sd, stage) < 0)
			rc = -1;
	}
	if (rc == 0) {
		emit_begin("cobaltRowsDone");
		emit_int("handle", handle);
		emit_str("table", table, 1);
		emit_int("rows", (long)rows);
		emit_int("tables", (long)tables);
		emit_end();
	}
	pi_buffer_free(buf);
}

/* "cobaltreadall HANDLE TABLE [FILTER]": 0xAE mit Selector 1 (Tabellen-
 * scan). FILTER fehlt oder "all": jede Zeile mit ihrem syncStatus,
 * gelöschte eingeschlossen. "modified" (nur seit dem Token geänderte
 * Zeilen) ist noch nicht freigegeben: der Filterwert ist unbestätigt
 * (Planning/cobalt-pim.md, Abschnitt 3.2 und row-commands 14). */
static void cobalt_read_all(int sd, const char *args)
{
	int handle, n;
	char table[COBALT_NAME_MAX], filter[16];
	struct cobalt_req r;

	filter[0] = '\0';
	n = sscanf(args, "%i %63s %15s", &handle, table, filter);
	if (n < 2 || handle < 1 || handle > 255 || strlen(table) > 31) {
		emit_error("cobaltreadall", "usage: cobaltreadall HANDLE TABLE [all|modified]");
		return;
	}
	if (strcmp(filter, "modified") == 0) {
		/* TODO: filter mask for "changed since the sync clock" (0x2000?
		 * bit 31?) is unconfirmed; needs a device with a stored token. */
		emit_error("cobaltreadall", "the modified-rows filter is not supported yet (filter value unknown)");
		return;
	}
	if (filter[0] != '\0' && strcmp(filter, "all") != 0 && strcmp(filter, "0") != 0) {
		emit_error("cobaltreadall", "usage: cobaltreadall HANDLE TABLE [all|modified]");
		return;
	}
	req_init(&r);
	req_u8(&r, (unsigned)handle);
	req_u32(&r, 1);				/* selector: table scan */
	req_u32(&r, COBALT_ROW_FIELDS);
	req_u32(&r, 0);				/* filter: every row */
	req_u32(&r, 1);				/* matchMode any */
	req_u32(&r, 0);				/* numCats: all categories */
	req_u16(&r, 0);
	req_u8(&r, 0);				/* the unexplained extra byte */
	req_bytes(&r, table, strlen(table) + 1);	/* C string, no length */
	cobalt_read_rows_exec(sd, "cobaltreadall", handle, table, &r);
}

/* "cobaltreadrows HANDLE ROWID[,ROWID...]": 0xAE mit Selector 0, die
 * genannten Zeilen (dezimal oder 0x-hex). Eine unbekannte ID kommt als
 * Zeile mit err (5) und ohne Spalten zurück. Der Ausweg für Ergebnisse,
 * die nicht in eine Nachricht passen. */
static void cobalt_read_rows(int sd, const char *args)
{
	int handle, n = 0;
	char list[4096];
	const char *p;
	uint32_t ids[COBALT_READROWS_MAX];
	struct cobalt_req r;
	int i;

	list[0] = '\0';
	if (sscanf(args, "%i %4095s", &handle, list) < 2 || handle < 1 || handle > 255) {
		emit_error("cobaltreadrows", "usage: cobaltreadrows HANDLE ROWID[,ROWID...]");
		return;
	}
	p = list;
	while (*p != '\0') {
		char *end;
		unsigned long v = strtoul(p, &end, 0);
		if (end == p || v > 0xFFFFFFFFul || (*end != ',' && *end != '\0') || n >= COBALT_READROWS_MAX) {
			emit_error("cobaltreadrows", "bad row id list (up to %d ids, decimal or 0x hex, comma separated)",
				   COBALT_READROWS_MAX);
			return;
		}
		ids[n++] = (uint32_t)v;
		p = (*end == ',') ? end + 1 : end;
	}
	if (n == 0) {
		emit_error("cobaltreadrows", "usage: cobaltreadrows HANDLE ROWID[,ROWID...]");
		return;
	}
	req_init(&r);
	req_u8(&r, (unsigned)handle);
	req_u32(&r, 0);				/* selector: row ids */
	req_u32(&r, COBALT_ROW_FIELDS);
	req_u32(&r, (uint32_t)n);
	req_u16(&r, 0);
	req_u8(&r, 0);
	for (i = 0; i < n; i++)
		req_u32(&r, ids[i]);
	cobalt_read_rows_exec(sd, "cobaltreadrows", handle, "", &r);
}

static int wait_for_command(int sd)
{
	struct pollfd in = { .fd = STDIN_FILENO, .events = POLLIN };

	for (;;) {
		int ready = poll(&in, 1, TICKLE_INTERVAL_MS);

		if (ready > 0)
			return 1;
		if (ready < 0 && errno != EINTR) {
			emit_error("command", "cannot wait for commands (%s)", strerror(errno));
			return 0;
		}
		if (ready == 0 && pi_tickle(sd) < 0) {
			emit_error("tickle", "the Palm does not answer any more");
			return 0;
		}
	}
}

/* Liest Anweisungen bis "end" oder EOF. Bei EOF (App weg) wird die
 * Sitzung trotzdem sauber beendet, damit der Palm nicht hängen bleibt. */
static void run_commands(int sd)
{
	/* ein Datensatz (bis 64 KiB) als Base64 muss in eine Zeile passen */
	static char line[100000];

	/* ungepuffert: was poll() als lesbar meldet, liegt nicht schon in
	 * einem stdio-Puffer, auf den poll() nicht schaut */
	setvbuf(stdin, NULL, _IONBF, 0);

	while (wait_for_command(sd) && fgets(line, sizeof(line), stdin) != NULL) {
		line[strcspn(line, "\r\n")] = '\0';

		if (strncmp(line, "install ", 8) == 0) {
			install_file(sd, line + 8);
		} else if (strncmp(line, "backup ", 7) == 0) {
			backup(sd, line + 7);
		} else if (strncmp(line, "getrom ", 7) == 0) {
			get_rom(sd, line + 7);
		} else if (strncmp(line, "setuser ", 8) == 0) {
			write_user(sd, line + 8);
		} else if (strncmp(line, "opendb ", 7) == 0) {
			open_database(sd, line + 7);
		} else if (strcmp(line, "closedb") == 0) {
			close_database(sd);
		} else if (strcmp(line, "readappinfo") == 0) {
			read_app_info(sd);
		} else if (strncmp(line, "writeappinfo ", 13) == 0) {
			write_app_info(sd, line + 13);
		} else if (strcmp(line, "readall") == 0) {
			read_records(sd, 0);
		} else if (strcmp(line, "readmodified") == 0) {
			read_records(sd, 1);
		} else if (strncmp(line, "readrec ", 8) == 0) {
			read_record(sd, line + 8);
		} else if (strncmp(line, "writerec ", 9) == 0) {
			write_record(sd, line + 9);
		} else if (strncmp(line, "deleterec ", 10) == 0) {
			delete_record(sd, line + 10);
		} else if (strncmp(line, "deletedb ", 9) == 0) {
			delete_database(sd, line + 9);
		} else if (strcmp(line, "resetflags") == 0) {
			reset_flags(sd);
		} else if (strcmp(line, "cleanup") == 0) {
			clean_up(sd);
		} else if (strncmp(line, "syncinfo ", 9) == 0) {
			write_sync_info(sd, line + 9);
		} else if (strcmp(line, "settime") == 0) {
			set_time(sd, 0);
		} else if (strncmp(line, "settime ", 8) == 0) {
			set_time(sd, atol(line + 8));
		} else if (strncmp(line, "netsync ", 8) == 0) {
			write_net_sync(sd, line + 8);
		} else if (strncmp(line, "log ", 4) == 0) {
			char entry[1024];
			utf8_to_cp1252(line + 4, entry, sizeof(entry));
			/* Der Palm zeigt jeden Eintrag als eigene Zeile im HotSync-Log */
			strncat(entry, "\n", sizeof(entry) - strlen(entry) - 1);
			dlp_AddSyncLogEntry(sd, entry);
		} else if (strncmp(line, "relaykey ", 9) == 0) {
			relay_set_key(line + 9);
		} else if (strncmp(line, "relaytls ", 9) == 0) {
			relay_set_transport(line + 9);
		} else if (strncmp(line, "relaypair", 9) == 0 && (line[9] == ' ' || line[9] == '\0')) {
			relay_set_pair(line[9] == ' ' ? line + 10 : line + 9);
		} else if (strncmp(line, "relay ", 6) == 0) {
			if (relay_session(sd, line + 6))
				break;	/* the server has ended the session */
		} else if (strncmp(line, "rawdlp ", 7) == 0) {
			raw_dlp(sd, line + 7);
		} else if (strcmp(line, "cobaltlist") == 0) {
			cobalt_list(sd);
		} else if (strncmp(line, "cobaltopen ", 11) == 0) {
			cobalt_open(sd, line + 11);
		} else if (strncmp(line, "cobaltclose ", 12) == 0) {
			cobalt_close(sd, line + 12);
		} else if (strncmp(line, "cobalttables ", 13) == 0) {
			cobalt_tables(sd, line + 13);
		} else if (strncmp(line, "cobaltschema ", 13) == 0) {
			cobalt_schema(sd, line + 13);
		} else if (strncmp(line, "cobaltcategories ", 17) == 0) {
			cobalt_categories(sd, line + 17);
		} else if (strncmp(line, "cobaltsyncstate ", 16) == 0) {
			cobalt_sync_state(sd, line + 16);
		} else if (strncmp(line, "cobaltrowcount ", 15) == 0) {
			cobalt_row_count(sd, line + 15);
		} else if (strncmp(line, "cobaltreadall ", 14) == 0) {
			cobalt_read_all(sd, line + 14);
		} else if (strncmp(line, "cobaltreadrows ", 15) == 0) {
			cobalt_read_rows(sd, line + 15);
		} else if (strcmp(line, "end") == 0) {
			break;
		} else if (line[0] != '\0') {
			emit_error("command", "unknown command: %s", line);
		}
	}
}

int main(int argc, char **argv)
{
	const char *port = NULL;
	int timeout = 0;
	int sd, i;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--port") == 0 && i + 1 < argc)
			port = argv[++i];
		else if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc)
			timeout = atoi(argv[++i]);
		else if (strcmp(argv[i], "--dlp") == 0 && i + 1 < argc) {
			/* Die DLP-Version, die wir dem Palm nennen (ReadSysInfo). Palm OS
			 * Cobalt (6.x) bricht den HotSync ab, wenn der Desktop weniger
			 * als 2 nennt; pilot-link nennt von sich aus 1.4. Ein Palm OS
			 * bis 5 richtet sich nach der Version, die er selbst spricht. */
			int major = 0, minor = 0;
			if (sscanf(argv[++i], "%d.%d", &major, &minor) != 2 || major < 1) {
				fprintf(stderr, "usage: %s --port PORT [--timeout SECONDS] [--dlp MAJOR.MINOR]\n", argv[0]);
				return 1;
			}
			dlp_set_protocol_version(major, minor);
		} else {
			fprintf(stderr, "usage: %s --port PORT [--timeout SECONDS] [--dlp MAJOR.MINOR]\n", argv[0]);
			return 1;
		}
	}
	if (port == NULL) {
		fprintf(stderr, "usage: %s --port PORT [--timeout SECONDS] [--dlp MAJOR.MINOR]\n", argv[0]);
		return 1;
	}

	sd = connect_palm(port, timeout);
	if (sd == -2)
		return 2;
	if (sd < 0)
		return 1;

	if (report_identity(sd) < 0) {
		pi_close(sd);
		return 1;
	}

	if (dlp_OpenConduit(sd) < 0) {
		emit_error("conduit", "cancelled on the Palm");
		pi_close(sd);
		return 1;
	}

	run_commands(sd);

	if (open_db >= 0)
		dlp_CloseDB(sd, open_db);
	if (!session_relayed)
		dlp_EndOfSync(sd, dlpEndCodeNormal);
	pi_close(sd);

	emit_begin("finished");
	emit_end();
	return 0;
}
