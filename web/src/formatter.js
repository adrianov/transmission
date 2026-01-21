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

  // Handle merged resolution patterns like "BDRip1080p" -> "BDRip 1080p"
  title = title.replaceAll(
    /(BDRip|HDRip|DVDRip|WEBRip)(1080p|720p|2160p|480p)/gi,
    '$1 $2',
  );

  // Resolution patterns
  const resMatch = title.match(/\b(2160p|1080p|720p|480p)\b/i);
  let resolution = resMatch ? resMatch[1] : null;
  if (!resolution) {
    const uhd = title.match(/\b(4K|UHD)\b/i);
    if (uhd) {
      resolution = '2160p';
    }
  }

  // Season pattern (S01, Season 1, etc.)
  const seasonMatch = title.match(/\bS(\d{1,2})(?:E\d+)?\b/i);
  const season = seasonMatch
    ? `Season ${Number.parseInt(seasonMatch[1], 10)}`
    : null;

  // Year pattern (standalone 4-digit year between 1900-2099)
  const yearMatch = title.match(/\b(19\d{2}|20\d{2})\b/);
  const year = yearMatch ? yearMatch[1] : null;

  // Date pattern for dated content (YY.MM.DD) - extract position for ordering
  const dateMatch = title.match(/\b(\d{2}\.\d{2}\.\d{2})\b/);
  const date = dateMatch ? dateMatch[1] : null;
  const dateIndex = dateMatch ? title.indexOf(dateMatch[0]) : -1;

  // Remove tech tags
  const allTags = [
    ...techTagsVideo,
    ...techTagsCodec,
    ...techTagsAudio,
    ...techTagsHdr,
    ...techTagsSource,
    ...techTagsOther,
  ];
  for (const tag of allTags) {
    title = title.replaceAll(new RegExp(`\\b${tag}\\b`, 'gi'), '');
  }

  // Remove resolution, season markers, year, date
  title = title
    .replaceAll(/\b(2160p|1080p|720p|480p|4K|UHD)\b/gi, '')
    .replaceAll(/\bS\d{1,2}(E\d+)?\b/gi, '')
    .replace(/\b(19\d{2}|20\d{2})\b/, '')
    .replace(/\b\d{2}\.\d{2}\.\d{2}\b/, '');

  // Replace dots/underscores with spaces, preserve existing " - "
  title = title
    .replaceAll(/[._]/g, ' ')
    .replaceAll(' - ', '\u0000')
    .replaceAll('-', ' ')
    .replaceAll('\u0000', ' - ')
    .replaceAll(/\s+/g, ' ')
    .trim();

  // Remove trailing/leading hyphens and spaces
  while (title.startsWith(' ') || title.startsWith('-')) {
    title = title.slice(1);
  }
  while (title.endsWith(' ') || title.endsWith('-')) {
    title = title.slice(0, -1);
  }

  // For dated content, split title at date position to get prefix and suffix
  let titlePrefix = title;
  let titleSuffix = '';
  if (date && dateIndex > 0) {
    // Estimate where the date was in the cleaned title (rough approximation)
    const words = title.split(/\s+/);
    // First word is usually the site/series name for dated content
    if (words.length > 1) {
      [titlePrefix] = words;
      titleSuffix = words.slice(1).join(' ');
    }
  }

  // Build the final title
  let result = titlePrefix;

  if (season) {
    result += ` - ${season}`;
  }
  if (date) {
    result += ` - ${date}`;
    if (titleSuffix) {
      result += ` - ${titleSuffix}`;
    }
  }
  if (year && !date) {
    result += ` (${year})`;
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
