/* @license This file Copyright © Mnemosyne LLC.
   It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
   or any future license endorsed by Mnemosyne LLC.
   License text can be found in the licenses/ folder. */

const plural_rules = new Intl.PluralRules();
const current_locale = plural_rules.resolvedOptions().locale;
const number_format = new Intl.NumberFormat(current_locale);

const kilo = 1000;
const mem_formatters = [
  new Intl.NumberFormat(current_locale, {
    maximumFractionDigits: 0,
    style: 'unit',
    unit: 'byte',
  }),
  new Intl.NumberFormat(current_locale, {
    maximumFractionDigits: 0,
    style: 'unit',
    unit: 'kilobyte',
  }),
  new Intl.NumberFormat(current_locale, {
    maximumFractionDigits: 0,
    style: 'unit',
    unit: 'megabyte',
  }),
  new Intl.NumberFormat(current_locale, {
    maximumFractionDigits: 2,
    style: 'unit',
    unit: 'gigabyte',
  }),
  new Intl.NumberFormat(current_locale, {
    maximumFractionDigits: 2,
    style: 'unit',
    unit: 'terabyte',
  }),
  new Intl.NumberFormat(current_locale, {
    maximumFractionDigits: 2,
    style: 'unit',
    unit: 'petabyte',
  }),
];

const fmt_kBps = new Intl.NumberFormat(current_locale, {
  maximumFractionDigits: 2,
  style: 'unit',
  unit: 'kilobyte-per-second',
});
const fmt_MBps = new Intl.NumberFormat(current_locale, {
  maximumFractionDigits: 2,
  style: 'unit',
  unit: 'megabyte-per-second',
});
const fmt_GBps = new Intl.NumberFormat(current_locale, {
  maximumFractionDigits: 2,
  style: 'unit',
  unit: 'gigabyte-per-second',
});

// Technical tags to filter from torrent names (split into groups to reduce regex complexity)
const techTagsVideo = [
  'WEBDL',
  'WEB-DL',
  'WEBRip',
  'BDRip',
  'BluRay',
  'HDRip',
  'DVDRip',
  'HDTV',
  'WEB-DLRip',
  'DLRip',
];

const techTagsCodec = [
  'HEVC',
  'H264',
  'H.264',
  'H265',
  'H.265',
  'x264',
  'x265',
  'AVC',
  '10bit',
];
const techTagsAudio = ['AAC', 'AC3', 'DTS', 'Atmos', 'TrueHD', 'FLAC', 'EAC3'];
const techTagsHdr = ['SDR', 'HDR', 'HDR10', 'DV', 'DoVi'];
const techTagsSource = ['AMZN', 'NF', 'DSNP', 'HMAX', 'PCOK', 'ATVP', 'APTV'];
const techTagsOther = [
  'ExKinoRay',
  'RuTracker',
  'LostFilm',
  'MP4',
  'IMAX',
  'REPACK',
  'PROPER',
  'EXTENDED',
  'UNRATED',
  'REMUX',
  'HDCLUB',
  'Jaskier',
  'MVO',
];

// VR/3D format tags to filter (technical, not content descriptors)
const techTagsVR = [
  '180x180',
  '180',
  '360',
  '3dh',
  '3dv',
  'LR',
  'TB',
  'SBS',
  'OU',
  'MKX200',
  'FISHEYE190',
  'RF52',
  'VRCA220',
];

const escapeRegex = (value) =>
  value.replaceAll(/[.*+?^${}()|[\]\\]/g, String.raw`\$&`);

/**
 * Converts a technical torrent name to a human-friendly title.
 *
 * Examples:
 *   Ponies.S01.1080p.PCOK.WEB-DL.H264 -> Ponies - Season 1 - 1080p
 *   Major.Grom.S01.2025.WEB-DL.HEVC.2160p -> Major Grom - Season 1 - 2160p
 *   Sting - Live At The Olympia Paris.2017.BDRip1080p -> Sting - Live At The Olympia Paris - 2017 - 1080p
 *   2ChicksSameTime.25.04.14.Bonnie.Rotten.2160p.mp4 -> 2ChickSameTime - 25.04.14 - Bonnie Rotten - 2160p
 */
function formatHumanTitle(name) {
  /* eslint-disable sonarjs/slow-regex, sonarjs/regex-complexity -- simple patterns on short title strings */
  if (!name) {
    return 'Unknown';
  }

  // Always replace underscores with spaces and collapse multiple whitespaces
  let title = name
    .replaceAll('_', ' ')
    .replaceAll('|', ' ')
    .replaceAll(/\s+l\s+/g, ' ')
    .replaceAll(',', ', ')
    .replaceAll(/\s+/g, ' ')
    .trim();

  // Extract year ellipsis interval (e.g. "1971...1977", "1971..1977") before removing it
  const earlyYearEllipsisMatch = title.match(
    /\b((?:19|20)\d{2})(?:\.{2,}|\u2026)((?:19|20)\d{2})\b/,
  );
  const earlyYearInterval = earlyYearEllipsisMatch
    ? `${earlyYearEllipsisMatch[1]}-${earlyYearEllipsisMatch[2]}`
    : null;

  // Remove year ellipsis pattern (e.g. "1971...1977", "1971..1977") early so later processing cannot alter dots
  title = title.replaceAll(
    /(?:19|20)\d{2}(?:\.{2,}|\u2026)(?:19|20)\d{2}/g,
    ' ',
  );

  // Ensure no space after '(' and no space before ')'
  title = title.replaceAll(/\(\s+/g, '(').replaceAll(/\s+\)/g, ')');
  // Ensure space before '(' when it follows a word character (e.g. NaughtyAmerica(NaughtyBookworms) -> NaughtyAmerica (NaughtyBookworms))
  title = title.replaceAll(/([\p{L}\p{N}])\(/gu, '$1 (');

  // Shortcut: if title already looks clean, return it (after initial cleanup)
  // Note: '.' is NOT in the clean regex, so any title with '.' will go through full processing.
  // Also check for technical patterns (resolution, season, year, tech tags) - if found, process the title
  const looksClean = /^[\p{L}\p{N}\s,()[\]{}\-:;]+$/u.test(title);
  if (looksClean) {
    const hasTechPatterns =
      /\b(?:2160p|1080p|720p|480p|8K|4K|UHD|S\d{1,2}|(?:19|20)\d{2}|DVD|BD|WEB|Rip|HEVC|H264|H265|x264|x265|AAC|AC3|DTS|FLAC|MP3|Jaskier|MVO|ExKinoRay|RuTracker)\b/i.test(
        title,
      );
    if (!hasTechPatterns) {
      return title;
    }
  }

  // Remove file extension (any 2-5 character alphanumeric extension)
  title = title.replace(/\.[a-z0-9]{2,5}$/i, '');

  // Normalize bracketed metadata early to simplify parsing
  title = title.replaceAll('[', ' ').replaceAll(']', ' ');
  title = title.replaceAll(/\s{2,}/g, ' ').trim();
  title = title.replaceAll(/\s-\s-\s+/g, ' - ');

  // Handle merged resolution patterns like "BDRip1080p" -> "BDRip 1080p"
  title = title.replaceAll(
    /(BDRip|HDRip|DVDRip|WEBRip)(1080p|720p|2160p|480p)/gi,
    '$1 $2',
  );

  // Resolution patterns
  const resMatch = title.match(/\b(2160p|1080p|720p|480p)\b/i);
  let resolution = resMatch ? resMatch[1] : null;
  if (!resolution) {
    const uhd = title.match(/\b(8K|4K|UHD)\b/i);
    if (uhd) {
      resolution = uhd[1].toUpperCase() === '8K' ? '8K' : '2160p';
    }
  }
  // DVD/BD format tags (shown as #DVD5, #BD50, etc.) - uppercase
  if (!resolution) {
    const discMatch = title.match(/\b(DVD5|DVD9|DVD|BD25|BD50|BD66|BD100)\b/i);
    if (discMatch) {
      resolution = discMatch[1].toUpperCase();
    }
  }
  // Legacy codecs and audio formats (shown as #xvid, #mp3, etc.) - lowercase
  // Also match Cyrillic МР3 (М=M, Р=P in Cyrillic)
  if (!resolution) {
    const formatMatch =
      title.match(
        /\b(XviD|DivX|MP3|FLAC|OGG|AAC|WAV|APE|ALAC|WMA|OPUS|M4A)\b/i,
      ) || title.match(/\(?(МР3|МРЗ)\)?/i);
    if (formatMatch) {
      // Normalize Cyrillic variants to mp3
      const fmt = formatMatch[1].toLowerCase();
      resolution = fmt === 'мр3' || fmt === 'мрз' ? 'mp3' : fmt;
    }
  }

  // Season pattern (S01, Season 1, etc.)
  const seasonMatch = title.match(/\bS(\d{1,2})(?:E\d+)?\b/i);
  const season = seasonMatch
    ? `Season ${Number.parseInt(seasonMatch[1], 10)}`
    : null;

  // Date pattern DD.MM.YYYY (e.g., 25.10.2021) - check BEFORE year to avoid partial match
  // Also match dates wrapped in parentheses like (25.10.2021)
  const fullDateMatch = title.match(/\(?(\d{2}\.\d{2}\.\d{4})\)?/);

  // Date pattern for dated content (YY.MM.DD, e.g., 25.04.14)
  const shortDateMatch = title.match(/\(?(\d{2}\.\d{2}\.\d{2})\)?/);

  // Use full date if found, otherwise short date
  const dateMatch = fullDateMatch || shortDateMatch;
  const date = dateMatch ? dateMatch[1] : null;

  // Year interval: hyphen (e.g. "2000-2003") or ellipsis (e.g. "1971...1977", "1971..1977")
  const yearIntervalHyphenMatch = title.match(
    /\b((?:19|20)\d{2})\s*-\s*((?:19|20)\d{2})\b/,
  );
  const yearInterval = yearIntervalHyphenMatch
    ? `${yearIntervalHyphenMatch[1]}-${yearIntervalHyphenMatch[2]}`
    : earlyYearInterval;

  // Year pattern (standalone 4-digit year between 1900-2099) - but not if it's part of a date or interval
  const year =
    fullDateMatch || yearInterval
      ? null
      : title.match(/\b(19\d{2}|20\d{2})\b/)?.[1] || null;

  // Remove tech tags
  // Allow optional separators (space/dot/string boundary) before/after tags
  const allTags = [
    ...techTagsVideo,
    ...techTagsCodec,
    ...techTagsAudio,
    ...techTagsHdr,
    ...techTagsSource,
    ...techTagsOther,
    ...techTagsVR,
  ];

  // Handle BluRay special case to preserve hyphen (Blu-Ray, BluRay -> removed)
  title = title.replaceAll(/(?:^|\.|\\s)Blu[\s-]*Ray(?:$|\\.|\\s)/gi, '');

  // Remove all other tech tags
  for (const tag of allTags) {
    if (tag === 'BluRay') {
      continue; // Already handled above
    }
    const escapedTag = escapeRegex(tag);
    title = title.replaceAll(
      new RegExp(`(?:^|\\.|\\s)${escapedTag}(?:$|\\.|\\s)`, 'gi'),
      ' ',
    );
  }

  // Remove resolution (optional leading dot or #). Do not remove surrounding parentheses:
  // e.g. "(1080p HD)" must become "( HD)" then cleaned, not " HD)" which leaves an unpaired ')'.
  title = title
    .replaceAll(/\.?#?\b(2160p|1080p|720p|480p|8K|4K|UHD)\b/gi, '')
    .replaceAll(/\.?#?\(?(DVD5|DVD9|DVD|BD25|BD50|BD66|BD100)\)?/gi, '')
    .replaceAll(
      /\.?#?\(?\b(XviD|DivX|MP3|FLAC|OGG|AAC|WAV|APE|ALAC|WMA|OPUS|M4A)\b\)?/gi,
      '',
    )
    .replaceAll(/\(?\(?(МР3|МРЗ)\)?/gi, '')
    .replaceAll(/\.?S\d{1,2}(E\d+)?\b/gi, '');
  // Remove year interval (hyphen or ellipsis) and preceding dot or surrounding parentheses
  if (yearInterval) {
    title = title.replace(/\.?\(?(?:19|20)\d{2}\s*-\s*(?:19|20)\d{2}\)?/, '');
    title = title.replaceAll(
      /(?:19|20)\d{2}(?:\.{2,}|\u2026)(?:19|20)\d{2}/g,
      '',
    );
    // Remove orphaned year-with-dots (e.g. "1971.." or "1971...") when second year was in different format
    title = title.replaceAll(/\b(?:19|20)\d{2}\.{2,}/g, '');
  }
  // Remove year only if not part of a full date or interval (and preceding dot or surrounding parentheses)
  if (year) {
    title = title.replace(/\.?\(?(19\d{2}|20\d{2})\)?/, '');
  }
  // Remove both date formats (DD.MM.YYYY and YY.MM.DD), including surrounding parentheses
  title = title
    .replace(/\(?\d{2}\.\d{2}\.\d{4}\)?/, '')
    .replace(/\(?\d{2}\.\d{2}\.\d{2}\)?/, '');

  // Replace dots with spaces if more than 2 words are glued with dots (e.g., Word.Word.Word)
  // or if the title uses dots as separators (no spaces at all)
  /* eslint-disable sonarjs/slow-regex -- simple patterns on short strings */
  const gluedDotsRegex = /[\p{L}\p{N}]+\.[\p{L}\p{N}]+\.[\p{L}\p{N}]+/u;
  const hasGluedDots = gluedDotsRegex.test(title);
  /* eslint-enable sonarjs/slow-regex */
  const hasNoSpaces = !title.includes(' ');
  if (hasGluedDots || (hasNoSpaces && title.includes('.'))) {
    title = title.replaceAll('.', ' ');
  }

  // Normalize separators, preserve existing " - "
  // Also preserve hyphens in compound words (e.g., "Blu-Ray")
  title = title
    .replaceAll(' - ', '\u0000')
    .replaceAll(/(?:^|\s)-(?:\s|$)/g, ' ')
    .replaceAll('\u0000', ' - ')
    .replaceAll(/\s+/g, ' ')
    .trim();

  // Clean up dots after all removals (artifacts from tag removal)
  // "Paris. .Bonus" -> "Paris. Bonus", "Paris .Bonus" -> "Paris Bonus"
  // Preserve "..." ellipsis
  /* eslint-disable sonarjs/slow-regex -- simple patterns on short strings */
  title = title
    .replaceAll(/\. +\./g, '. ')
    .replaceAll(/ +\.(\w)/g, ' $1')
    .replaceAll(/ +\.$/g, '')
    .replaceAll(/ +\. /g, ' ')
    .replaceAll(/([^.])\.$/g, '$1')
    .trim();
  /* eslint-enable sonarjs/slow-regex */

  // Remove empty parentheses and parentheticals that only contain HD/SD (artifacts from resolution/tag removal)
  title = title
    .replaceAll(/\(\s*\)/g, '')
    .replaceAll(/\(\s*(?:HD|SD)\s*\)/gi, '');

  // Remove trailing/leading hyphens and spaces (but not dots - they may be ellipsis)
  while (title.startsWith(' ') || title.startsWith('-')) {
    title = title.slice(1);
  }
  while (title.endsWith(' ') || title.endsWith('-')) {
    title = title.slice(0, -1);
  }

  // Build the final title
  let result = title;

  if (season) {
    result += ` - ${season}`;
  }
  if (yearInterval) {
    result += ` (${yearInterval})`;
  } else if (year && !date) {
    result += ` (${year})`;
  }
  if (date) {
    result += ` (${date})`;
  }
  if (resolution) {
    result += ` #${resolution}`;
  }

  // Final cleanup: ensure no space after '(' and no space before ')'
  /* eslint-disable-next-line sonarjs/slow-regex -- simple pattern on short string */
  result = result.replaceAll(/\(\s+/g, '(').replaceAll(/\s+\)/g, ')');
  result = result.replaceAll(/([\p{L}\p{N}])\(/gu, '$1 (');

  return result || name;
  /* eslint-enable sonarjs/regex-complexity */
}

/**
 * Converts a filename (or folder name) to a lightweight human-friendly label.
 *
 * This intentionally does not extract years/dates or strip technical tags.
 * It only replaces separator-heavy names ('.', '-', '_') with spaces.
 */
/* eslint-disable sonarjs/slow-regex -- simple patterns on short strings */
function formatHumanFileName(name) {
  if (!name) {
    return 'Unknown';
  }

  // Always replace underscores with spaces and collapse multiple whitespaces
  name = name
    .replaceAll('_', ' ')
    .replaceAll('|', ' ')
    .replaceAll(/\s+l\s+/g, ' ')
    .replaceAll(',', ', ')
    .replaceAll(/\s+/g, ' ')
    .trim();

  // Ensure no space after '(' and no space before ')'
  name = name.replaceAll(/\(\s+/g, '(').replaceAll(/\s+\)/g, ')');
  name = name.replaceAll(/([\p{L}\p{N}])\(/gu, '$1 (');

  // Keep the file extension intact if it looks like one.
  const lastDot = name.lastIndexOf('.');
  let base = name;
  let ext = '';
  if (lastDot > 0) {
    const tail = name.slice(lastDot + 1);
    if (tail.length > 0 && tail.length <= 5 && /^[a-z0-9]+$/i.test(tail)) {
      base = name.slice(0, lastDot);
      ext = name.slice(lastDot);
    }
  }

  let whitespaceCount = 0;
  let dotCount = 0;
  let hyphenCount = 0;
  let underscoreCount = 0;
  for (const ch of base) {
    switch (ch) {
      case ' ': {
        whitespaceCount += 1;

        break;
      }
      case '.': {
        dotCount += 1;

        break;
      }
      case '-': {
        hyphenCount += 1;

        break;
      }
      case '_': {
        underscoreCount += 1;

        break;
      }
      // No default
    }
  }

  const separatorCount = dotCount + hyphenCount + underscoreCount;
  const noSpaces = whitespaceCount === 0;
  const shouldReplaceSeparators =
    (separatorCount >= 3 && separatorCount > whitespaceCount) ||
    (noSpaces && (underscoreCount > 0 || dotCount >= 2 || hyphenCount >= 2));

  if (!shouldReplaceSeparators) {
    return name;
  }

  let out = '';
  for (let i = 0; i < base.length; i += 1) {
    const c = base[i];
    const prev = i > 0 ? base[i - 1] : '';
    const next = i + 1 < base.length ? base[i + 1] : '';
    const betweenDigits = /\d/.test(prev) && /\d/.test(next);

    switch (c) {
      case '_': {
        out += ' ';

        break;
      }
      case '.': {
        out += betweenDigits ? '.' : ' ';

        break;
      }
      case '-': {
        const spacedDash = prev === ' ' && next === ' ';
        const isLetter = /\p{L}/u;
        const isHyphenatedWord = isLetter.test(prev) && isLetter.test(next);
        out += betweenDigits || spacedDash || isHyphenatedWord ? '-' : ' ';

        break;
      }
      default: {
        out += c;
      }
    }
  }

  out = out.replaceAll(/\s+/g, ' ').trim();
  if (!out) {
    return name;
  }

  return `${out}${ext}`;
}
/* eslint-enable sonarjs/slow-regex */

export const Formatter = {
  /** Round a string of a number to a specified number of decimal places */
  _toTruncFixed(number, places) {
    const returnValue = Math.floor(number * 10 ** places) / 10 ** places;
    return returnValue.toFixed(places);
  },

  countString(msgid, msgid_plural, n) {
    return `${this.number(n)} ${this.ngettext(msgid, msgid_plural, n)}`;
  },

  /**
   * Detects episode title from a torrent name.
   * When SxxExx or 1x05 is present, displays both season and episode; title after the marker is shown only then (e.g. S1 E5 - Title).
   * Standalone E05 shows as E5 only, no title.
   *
   * Examples:
   *   Ponies.S01E01.The.Beginning.1080p -> S1 E1 - The Beginning
   *   Ponies.S01E01.1080p -> S1 E1
   *   Show.E05.standalone.mkv -> E5
   */
  episodeTitle(name, torrentName) {
    if (!name) {
      return '';
    }

    let episodePrefix = '';
    let matchEnd = 0;

    // Prefer SxxExx or 1x05: display both season and episode
    const seMatch = name.match(/\bS(\d{1,2})[.\s]?E(\d{1,3})\b/i);
    if (seMatch) {
      const season = Number.parseInt(seMatch[1], 10);
      const episode = Number.parseInt(seMatch[2], 10);
      episodePrefix = `S${season} E${episode}`;
      matchEnd = seMatch.index + seMatch[0].length;
    }
    if (!episodePrefix) {
      const altMatch = name.match(/\b(\d{1,2})x(\d{1,3})\b/i);
      if (altMatch) {
        const season = Number.parseInt(altMatch[1], 10);
        const episode = Number.parseInt(altMatch[2], 10);
        episodePrefix = `S${season} E${episode}`;
        matchEnd = altMatch.index + altMatch[0].length;
      }
    }
    if (!episodePrefix) {
      const episodeMatch = name.match(/\b(?:S?\d{1,2})?E(\d{1,3})\b/i);
      if (!episodeMatch) {
        return '';
      }
      const episodeNum = Number.parseInt(episodeMatch[1], 10);
      episodePrefix = `E${episodeNum}`;
      // Standalone episode only: do not extract title; show prefix only.
      return episodePrefix;
    }

    // Extract title from text after the episode marker (only when both season and episode were found)
    let remaining = name.slice(matchEnd);

    // If there's a dot or hyphen immediately after, skip it
    remaining = remaining.replace(/^[.\-\s]+/, '');

    if (!remaining) {
      return episodePrefix;
    }

    // Cleanup the remaining part using humanFileName logic
    let title = formatHumanFileName(remaining);

    // Aggressively strip technical tags from the episode title
    const tagsToStrip = [
      '1080p',
      '720p',
      '2160p',
      '480p',
      '8K',
      '4K',
      'UHD',
      'WEB-DL',
      'WEBDL',
      'WEBRip',
      'BDRip',
      'BluRay',
      'HDRip',
      'DVDRip',
      'HDTV',
      'WEB-DLRip',
      'DLRip',
      'H264',
      'H.264',
      'H265',
      'H.265',
      'x264',
      'x265',
      'HEVC',
      'AVC',
      'AMZN',
      'NF',
      'DSNP',
      'HMAX',
      'PCOK',
      'ATVP',
      'APTV',
      '2xRu',
      'Ru',
      'En',
      'qqss44',
      'WEB',
      'DL',
    ];

    // Remove any [Source]-?Rip variants from episode title
    title = title.replaceAll(/\b[a-z0-9]+-?rip\b/gi, '');

    // Remove any [Source]HD variants from episode title
    title = title.replaceAll(/\b[a-z0-9]+HD\b/gi, '');

    for (const tag of tagsToStrip) {
      const regex = new RegExp(`\\b${tag}\\b`, 'gi');
      title = title.replace(regex, '');
    }

    // Remove file extension (any 2-5 character alphanumeric extension)
    title = title.replace(/\.[a-z0-9]{2,5}$/i, '');

    // Final cleanup
    // Also remove empty brackets/parentheses like [] or ()
    title = title.replaceAll(/[([]\s*[)\]]/g, '');

    // Remove stray closing brackets or parentheses
    title = title.replaceAll(/[\])]/g, '');
    title = title.replaceAll('|', '');
    /* eslint-disable-next-line sonarjs/slow-regex -- simple pattern on short string */
    title = title.replaceAll(/\s+l\s+/g, ' ');

    title = title.replaceAll(/\s+/g, ' ').trim();
    while (
      title.startsWith('-') ||
      title.startsWith(' ') ||
      title.startsWith('.')
    ) {
      title = title.slice(1);
    }
    while (title.endsWith('-') || title.endsWith(' ') || title.endsWith('.')) {
      title = title.slice(0, -1);
    }

    // Final check for file extension
    if (title.toLowerCase().endsWith('mkv')) {
      title = title.slice(0, -3).trim();
      while (
        title.endsWith('-') ||
        title.endsWith(' ') ||
        title.endsWith('.')
      ) {
        title = title.slice(0, -1);
      }
    }

    if (title && title !== 'Unknown' && title.length > 1) {
      // If the title is just a repeat of the torrent name, it's garbage
      if (torrentName) {
        /* eslint-disable sonarjs/slow-regex -- simple pattern on short string */
        const cleanTorrentName = formatHumanTitle(torrentName)
          .replaceAll(/\s*(- Season \d+|\(\d{4}\)|#\d+p|#\w+)/gi, '')
          .trim();
        /* eslint-enable sonarjs/slow-regex */

        // Check if title is just the series name, or the series name + year
        if (title.toLowerCase() === cleanTorrentName.toLowerCase()) {
          return episodePrefix;
        }

        /* eslint-disable sonarjs/slow-regex -- simple pattern on short string */
        const titleWithoutYear = title
          .replaceAll(/\s*\(?\b(19|20)\d{2}\b\)?/g, '')
          .trim();
        /* eslint-enable sonarjs/slow-regex */
        if (titleWithoutYear.toLowerCase() === cleanTorrentName.toLowerCase()) {
          return episodePrefix;
        }
      }

      return `${episodePrefix} - ${title}`;
    }

    return episodePrefix;
  },

  /** Converts a filename/folder name to a lightweight human-friendly label */
  humanFileName(name) {
    return formatHumanFileName(name);
  },

  /** Converts technical torrent name to human-friendly title */
  humanTitle(name) {
    return formatHumanTitle(name);
  },

  // Formats a memory size into a human-readable string
  // @param {Number} bytes the filesize in bytes
  // @return {String} human-readable string
  mem(bytes) {
    if (bytes < 0) {
      return 'Unknown';
    }
    if (bytes === 0) {
      return 'None';
    }

    let size = bytes;
    for (const nf of mem_formatters) {
      if (size < kilo) {
        return nf.format(size);
      }
      size /= kilo;
    }

    return 'E2BIG';
  },

  ngettext(msgid, msgid_plural, n) {
    return plural_rules.select(n) === 'one' ? msgid : msgid_plural;
  },

  number(number) {
    return number_format.format(number);
  },

  // format a percentage to a string
  percentString(x, decimal_places) {
    decimal_places = x < 100 ? decimal_places : 0;
    return this._toTruncFixed(x, decimal_places);
  },

  /*
   *   Format a ratio to a string
   */
  ratioString(x) {
    if (x === -1) {
      return 'None';
    }
    if (x === -2) {
      return '&infin;';
    }
    return this.percentString(x, 1);
  },

  /**
   * Formats a disk capacity or file size into a human-readable string
   * @param {Number} bytes the filesize in bytes
   * @return {String} human-readable string
   */
  size(bytes) {
    return this.mem(bytes);
  },

  speed(KBps) {
    if (KBps < 999.95) {
      return fmt_kBps.format(KBps);
    } else if (KBps < 999_950) {
      return fmt_MBps.format(KBps / 1000);
    }
    return fmt_GBps.format(KBps / 1_000_000);
  },

  speedBps(Bps) {
    return this.speed(this.toKBps(Bps));
  },

  stringSanitizer(str) {
    return ['E2BIG', 'NaN'].some((badStr) => str.includes(badStr)) ? `…` : str;
  },

  timeInterval(seconds, granular_depth = 3) {
    const days = Math.floor(seconds / 86_400);
    let buffer = [];
    if (days) {
      buffer.push(this.countString('day', 'days', days));
    }

    const hours = Math.floor((seconds % 86_400) / 3600);
    if (days || hours) {
      buffer.push(this.countString('hour', 'hours', hours));
    }

    const minutes = Math.floor((seconds % 3600) / 60);
    if (days || hours || minutes) {
      buffer.push(this.countString('minute', 'minutes', minutes));
      buffer = buffer.slice(0, granular_depth);
      return buffer.length > 1
        ? `${buffer.slice(0, -1).join(', ')} and ${buffer.slice(-1)}`
        : buffer[0];
    }

    return this.countString('second', 'seconds', Math.floor(seconds % 60));
  },

  timestamp(seconds) {
    if (!seconds) {
      return 'N/A';
    }

    const myDate = new Date(seconds * 1000);
    const now = new Date();

    let date = '';
    let time = '';

    const sameYear = now.getFullYear() === myDate.getFullYear();
    const sameMonth = now.getMonth() === myDate.getMonth();

    const dateDiff = now.getDate() - myDate.getDate();
    if (sameYear && sameMonth && Math.abs(dateDiff) <= 1) {
      if (dateDiff === 0) {
        date = 'Today';
      } else if (dateDiff === 1) {
        date = 'Yesterday';
      } else {
        date = 'Tomorrow';
      }
    } else {
      date = myDate.toDateString();
    }

    let hours = myDate.getHours();
    let period = 'AM';
    if (hours > 12) {
      hours = hours - 12;
      period = 'PM';
    }
    if (hours === 0) {
      hours = 12;
    }
    if (hours < 10) {
      hours = `0${hours}`;
    }
    let minutes = myDate.getMinutes();
    if (minutes < 10) {
      minutes = `0${minutes}`;
    }
    seconds = myDate.getSeconds();
    if (seconds < 10) {
      seconds = `0${seconds}`;
    }

    time = [hours, minutes, seconds].join(':');

    return [date, time, period].join(' ');
  },

  toKBps(Bps) {
    return Math.floor(Bps / kilo);
  },
};
