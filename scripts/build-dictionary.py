#!/usr/bin/env python3
"""Build the companion's offline dictionary from English Wiktionary.

    python3 -I scripts/build-dictionary.py models/source/kaikki-English.jsonl.gz models/dictionary.sqlite

The source is kaikki.org's extract of English Wiktionary (wiktextract, CC BY-SA
and GFDL, as Wiktionary is): every English word, its senses, and the
translation tables editors keep for each sense. From it, two tables:

    translations  english word -> word in one of the languages below, with
                  the sense it is for and a romanisation where there is one;
                  read both ways, so "what does köszönöm mean" works too
    meanings      english word -> its first few definitions

Only the languages the companion is asked about are kept (the owner's list,
2026-10-21).
"""

import gzip
import json
import sqlite3
import sys

# Wiktionary's codes for them. Norwegian comes as Bokmål, Nynorsk or plain;
# Chinese mostly as Mandarin.
LANGUAGES = {
    "fr": "fr", "it": "it", "es": "es", "de": "de", "nl": "nl",
    "nb": "nb", "nn": "nb", "no": "nb", "sv": "sv", "da": "da", "fi": "fi",
    "hu": "hu", "pl": "pl", "ro": "ro", "ru": "ru", "cmn": "cmn", "zh": "cmn", "ja": "ja",
}
MEANINGS_PER_ENTRY = 2
# Parts of speech as one letter: n(oun), v(erb), a(djective), r (adverb), p(hrase), o(ther).
POS = {"noun": "n", "name": "n", "verb": "v", "adj": "a", "adv": "r", "phrase": "p", "intj": "p", "prep_phrase": "p"}
GLOSS_LENGTH = 200
TRANSLATIONS_PER_SENSE = 2
SENSES_PER_LANGUAGE = 3


def main(source, target):
    db = sqlite3.connect(target)
    db.executescript("""
        DROP TABLE IF EXISTS translations;
        DROP TABLE IF EXISTS meanings;
        DROP TABLE IF EXISTS senses;
        DROP TABLE IF EXISTS words;
        CREATE TABLE words (id INTEGER PRIMARY KEY, text TEXT UNIQUE);
        CREATE TABLE senses (id INTEGER PRIMARY KEY, text TEXT UNIQUE);
        CREATE TABLE translations (english INTEGER, pos TEXT, sense INTEGER, lang TEXT, word TEXT COLLATE NOCASE, roman TEXT);
        CREATE TABLE meanings (word INTEGER, pos TEXT, rank INTEGER, gloss TEXT);
    """)
    entries = translations = meanings = 0
    glossed = set()
    ids = {}

    def word_id(text):
        if text not in ids:
            ids[text] = db.execute("INSERT INTO words (text) VALUES (?)", (text,)).lastrowid
        return ids[text]
    with gzip.open(source, "rt", encoding="utf-8") as lines:
        try:
            for line in lines:
                entry = json.loads(line)
                if entry.get("lang_code", "en") != "en":
                    continue
                word = entry.get("word", "").strip()
                if not word or len(word) > 60:
                    continue
                key, pos = word.lower(), POS.get(entry.get("pos", ""), "")
                # Translation tables hang off each sense (and, in older
                # extracts, the entry itself).
                senses = entry.get("senses", [])
                tables = entry.get("translations", []) + [t for sense in senses for t in sense.get("translations", [])]
                # Only words someone made a translation table for: everyday
                # vocabulary, not the million and a half rare entries, which
                # made the file 222 MB.
                if not tables:
                    continue
                entries += 1
                key = word_id(key)
                rank = 0
                for sense in senses:
                    for gloss in sense.get("glosses", [])[:1]:
                        if rank < MEANINGS_PER_ENTRY and "form of" not in gloss.lower():
                            if len(gloss) > GLOSS_LENGTH:
                                gloss = gloss[:GLOSS_LENGTH].rsplit(" ", 1)[0] + "…"
                            if (key, gloss) in glossed:
                                continue
                            glossed.add((key, gloss))
                            db.execute("INSERT INTO meanings VALUES (?,?,?,?)", (key, pos, rank, gloss))
                            rank += 1
                            meanings += 1
                kept = {}
                senses_kept = {}
                for t in tables:
                    lang = LANGUAGES.get(t.get("lang_code") or t.get("code") or "")
                    foreign = (t.get("word") or "").strip()
                    if not lang or not foreign or len(foreign) > 60:
                        continue
                    sense = t.get("sense", "")
                    count = kept.get((lang, sense), 0)
                    if count >= TRANSLATIONS_PER_SENSE:
                        continue
                    seen = senses_kept.setdefault(lang, [])
                    if sense not in seen:
                        if len(seen) >= SENSES_PER_LANGUAGE:
                            continue
                        seen.append(sense)
                    kept[(lang, sense)] = count + 1
                    db.execute("INSERT OR IGNORE INTO senses (text) VALUES (?)", (sense,))
                    sense_id = db.execute("SELECT id FROM senses WHERE text = ?", (sense,)).fetchone()[0]
                    db.execute("INSERT INTO translations VALUES (?,?,?,?,?,?)",
                               (key, pos, sense_id, lang, foreign, t.get("roman", "")))
                    translations += 1
        except EOFError:
            print("note: the source ended early (a partial download?); built from what was there", file=sys.stderr)
    db.executescript("""
        CREATE INDEX translations_english ON translations (english, lang);
        CREATE INDEX meanings_word ON meanings (word);
        CREATE INDEX translations_word ON translations (word COLLATE NOCASE);

    """)
    db.commit()
    db.execute("VACUUM")
    db.close()
    print(f"{entries} English entries: {translations} translations, {meanings} meanings -> {target}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
