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
  if (!name) {
    return 'Unknown';
  }

  // Remove file extension
  let title = name.replace(
    /\.(mkv|avi|mp4|mov|wmv|flv|webm|m4v|torrent)$/i,
    '',
  );

  // Extract year and format from square bracket metadata like [2006, Documentary, DVD5]
  // Keep content descriptors (Documentary, etc.), only extract year and disc format
  /* eslint-disable sonarjs/slow-regex -- simple patterns on short strings */
  const bracketMatch = title.match(/\[([^\]]+)\]/);
  let bracketYear = null;
  let bracketFormat = null;
  if (bracketMatch) {
    const [, bracketContent] = bracketMatch;
    const bracketYearMatch = bracketContent.match(/\b(19\d{2}|20\d{2})\b/);
    if (bracketYearMatch) {
      [, bracketYear] = bracketYearMatch;
    }
    // Extract disc format from brackets
    const bracketFormatMatch = bracketContent.match(
      /\b(DVD5|DVD9|DVD|BD25|BD50|BD66|BD100)\b/i,
    );
    if (bracketFormatMatch) {
      bracketFormat = bracketFormatMatch[1].toUpperCase();
    }
    // Remove only year and disc format from bracket content, keep the rest
    const cleanedBracket = bracketContent
      .replaceAll(/\b(19\d{2}|20\d{2})\b/g, '')
      .replaceAll(/\b(?:DVD5|DVD9|DVD|BD25|BD50|BD66|BD100)\b/gi, '')
      .replaceAll(/,\s*,/g, ',')
      .replaceAll(/^[\s,]+/g, '')
      .replaceAll(/[\s,]+$/g, '')
      .trim();
    // If bracket still has content, keep it; otherwise remove brackets entirely
    title = cleanedBracket
      ? title.replace(/\[([^\]]+)\]/, `[${cleanedBracket}]`)
      : title.replaceAll(/\s*\[([^\]]+)\]\s*/g, ' ');
  }
  /* eslint-enable sonarjs/slow-regex */

  // Handle merged resolution patterns like "BDRip1080p" -> "BDRip 1080p"
  title = title.replaceAll(
    /(BDRip|HDRip|DVDRip|WEBRip)(1080p|720p|2160p|480p)/gi,
    '$1 $2',
  );

  // Normalize underscore before resolution (e.g., "_1080p" -> " 1080p")
  title = title.replaceAll('_', ' ');

  // Resolution patterns
  const resMatch = title.match(/\b(2160p|1080p|720p|480p)\b/i);
  let resolution = resMatch ? resMatch[1] : null;
  if (!resolution) {
    const uhd = title.match(/\b(8K|4K|UHD)\b/i);
    if (uhd) {
      resolution = uhd[1].toUpperCase() === '8K' ? '8K' : '2160p';
    }
  }
  // DVD/BD format tags (shown as #DVD5, #BD50, etc.)
  if (!resolution) {
    const discMatch = title.match(/\b(DVD5|DVD9|DVD|BD25|BD50|BD66|BD100)\b/i);
    if (discMatch) {
      resolution = discMatch[1].toUpperCase();
    }
  }
  // Use format extracted from brackets if no other resolution found
  if (!resolution && bracketFormat) {
    resolution = bracketFormat;
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

  // Year pattern (standalone 4-digit year between 1900-2099) - but not if it's part of a date
  // Also use year extracted from bracket metadata if no other year found
  let year = fullDateMatch
    ? null
    : title.match(/\b(19\d{2}|20\d{2})\b/)?.[1] || null;
  if (!year && bracketYear) {
    year = bracketYear;
  }

  // Remove tech tags
  const allTags = [
    ...techTagsVideo,
    ...techTagsCodec,
    ...techTagsAudio,
    ...techTagsHdr,
    ...techTagsSource,
    ...techTagsOther,
    ...techTagsVR,
  ];
  for (const tag of allTags) {
    title = title.replaceAll(new RegExp(`\\.?${tag}\\b`, 'gi'), '');
  }

  // Remove resolution, season markers, year, date (and preceding dot if used as separator)
  title = title
    .replaceAll(
      /\.?(2160p|1080p|720p|480p|8K|4K|UHD|DVD5|DVD9|DVD|BD25|BD50|BD66|BD100)\b/gi,
      '',
    )
    .replaceAll(/\.?S\d{1,2}(E\d+)?\b/gi, '');
  // Remove year only if not part of a full date (and preceding dot or surrounding parentheses)
  if (year) {
    title = title.replace(/\.?\(?(19\d{2}|20\d{2})\)?/, '');
  }
  // Remove both date formats (DD.MM.YYYY and YY.MM.DD), including surrounding parentheses
  title = title
    .replace(/\(?\d{2}\.\d{2}\.\d{4}\)?/, '')
    .replace(/\(?\d{2}\.\d{2}\.\d{2}\)?/, '');

  // Only replace dots with spaces if title uses dots as separators (no spaces)
  const hasDotSeparators = !title.includes(' ') && title.includes('.');
  if (hasDotSeparators) {
    title = title.replaceAll(/[.]/g, ' ');
  }

  // Normalize separators, preserve existing " - "
  title = title
    .replaceAll(' - ', '\u0000')
    .replaceAll('-', ' ')
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
  if (year && !date) {
    result += ` (${year})`;
  }
  if (date) {
    result += ` (${date})`;
  }
  if (resolution) {
    result += ` #${resolution}`;
  }

  return result || name;
}

export const Formatter = {
  /** Round a string of a number to a specified number of decimal places */
  _toTruncFixed(number, places) {
    const returnValue = Math.floor(number * 10 ** places) / 10 ** places;
    return returnValue.toFixed(places);
  },

  countString(msgid, msgid_plural, n) {
    return `${this.number(n)} ${this.ngettext(msgid, msgid_plural, n)}`;
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
