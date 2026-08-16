/* @license This file Copyright © Mnemosyne LLC.
   It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
   or any future license endorsed by Mnemosyne LLC.
   License text can be found in the licenses/ folder. */

const techTagsVideo = [
  'WEBDL',
  'WEB-DL',
  'WEBRip',
  'BDRip',
  'BDRemux',
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
const techTagsAudio = [
  'AAC',
  'AAC2.0',
  'AAC5.1',
  'AC3',
  'DD5.1',
  'DD2.0',
  'DD5',
  'DD2',
  'DDP5.1',
  'DDP2.0',
  'DDP5',
  'DDP2',
  'DTS',
  'DTS-HD',
  'Atmos',
  'TrueHD',
  'FLAC',
  'EAC3',
];
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

const episodeTagsToStrip = [
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
  'BDRemux',
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
  '10bit',
  'DD5.1',
  'DD2.0',
  'DD5',
  'DD2',
  'DDP5.1',
  'DDP2.0',
  'DDP5',
  'DDP2',
  'Atmos',
  'TrueHD',
  'DTS',
  'DTS-HD',
  'EAC3',
  'EAC',
  'AC3',
  'AAC',
  'AAC2.0',
  'AAC5.1',
  'PROPER',
  'REPACK',
  'EXTENDED',
  'UNRATED',
  'REMUX',
  'HDR',
  'HDR10',
  'DV',
  'DoVi',
  'SDR',
  'IMAX',
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

const escapeRegex = (value) =>
  value.replaceAll(/[.*+?^${}()|[\]\\]/g, String.raw`\$&`);

/* eslint-disable sonarjs/slow-regex -- short title strings */
const tightenParens = (text) =>
  text
    .replaceAll(/\(\s+/g, '(')
    .replaceAll(/\s+\)/g, ')')
    .replaceAll(/([\p{L}\p{N}])\(/gu, '$1 (');

const normalizeSeparators = (text) =>
  text
    .replaceAll('_', ' ')
    .replaceAll('+', ' ')
    .replaceAll('|', ' ')
    .replaceAll(/\s+l\s+/g, ' ')
    .replaceAll(',', ', ')
    .replaceAll(/\s+/g, ' ')
    .trim();
/* eslint-enable sonarjs/slow-regex */

const trimEdgeHyphens = (text) => {
  let out = text;
  while (out.startsWith(' ') || out.startsWith('-')) {
    out = out.slice(1);
  }
  while (out.endsWith(' ') || out.endsWith('-')) {
    out = out.slice(0, -1);
  }
  return out;
};

/**
 * Turns a technical torrent or file name into a human-friendly display title.
 */
export class HumanTitle {
  constructor(raw) {
    this.raw = raw || '';
    this.title = '';
    this.resolution = null;
    this.season = null;
    this.date = null;
    this.year = null;
    this.yearInterval = null;
    this.hadGluedDots = false;
  }

  /** Converts a technical torrent name to a human-friendly title. */
  static format(name) {
    return new HumanTitle(name).toDisplay();
  }

  /** Lightweight filename/folder label (separators only, no year/tag stripping). */
  static fileName(name) {
    // eslint-disable-next-line no-use-before-define -- defined below the class
    return formatHumanFileName(name);
  }

  /**
   * Episode label from a filename. SxxExx / 1x05 show season and episode;
   * a title after the marker is kept only then. Standalone E05 is E5 only.
   */
  static episodeTitle(name, torrentName) {
    // eslint-disable-next-line no-use-before-define -- defined below the class
    return formatEpisodeTitle(name, torrentName);
  }

  toDisplay() {
    /* eslint-disable sonarjs/slow-regex -- simple patterns on short title strings */
    if (!this.raw) {
      return 'Unknown';
    }
    this.prepare();
    if (this.isClean()) {
      return this.title;
    }
    this.stripExtensionAndBrackets();
    this.extractFields();
    this.stripTechAndExtracted();
    this.normalizeRemainder();
    return this.assemble() || this.raw;
  }

  prepare() {
    this.title = normalizeSeparators(this.raw);
    const earlyYearEllipsisMatch = this.title.match(
      /\b((?:19|20)\d{2})(?:\.{2,}|\u2026)((?:19|20)\d{2})\b/,
    );
    this.yearInterval = earlyYearEllipsisMatch
      ? `${earlyYearEllipsisMatch[1]}-${earlyYearEllipsisMatch[2]}`
      : null;
    this.title = this.title.replaceAll(
      /(?:19|20)\d{2}(?:\.{2,}|\u2026)(?:19|20)\d{2}/g,
      ' ',
    );
    this.title = tightenParens(this.title);
  }

  isClean() {
    if (!/^[\p{L}\p{N}\s,()[\]{}\-:;]+$/u.test(this.title)) {
      return false;
    }
    /* eslint-disable-next-line sonarjs/regex-complexity -- known tech-tag list */
    return !/\b(?:2160p|1080p|720p|480p|8K|4K|UHD|S\d{1,2}|(?:19|20)\d{2}|DVD|BD|WEB|Rip|HEVC|H264|H265|x264|x265|AAC|AC3|DTS|FLAC|MP3|Jaskier|MVO|ExKinoRay|RuTracker)\b/i.test(
      this.title,
    );
  }

  stripExtensionAndBrackets() {
    this.title = this.title.replace(/\.[a-z0-9]{2,5}$/i, '');
    this.title = this.title.replaceAll(/\{[^}]*\}/g, ' ');
    this.title = this.title.replaceAll('[', ' ').replaceAll(']', ' ');
    this.title = this.title.replaceAll(/\s{2,}/g, ' ').trim();
    this.title = this.title.replaceAll(/\s-\s-\s+/g, ' - ');
    this.title = this.title.replaceAll(
      /(BDRip|HDRip|DVDRip|WEBRip)(1080p|720p|2160p|480p)/gi,
      '$1 $2',
    );
  }

  extractFields() {
    this.extractResolution();
    this.extractSeason();
    this.extractDateAndYear();
    this.hadGluedDots = /[\p{L}\p{N}]+\.[\p{L}\p{N}]+\.[\p{L}\p{N}]+/u.test(
      this.title,
    );
  }

  extractResolution() {
    const resMatch = this.title.match(/\b(2160p|1080p|720p|480p)\b/i);
    if (resMatch) {
      const [, resolution] = resMatch;
      this.resolution = resolution;
      return;
    }
    this.resolution =
      this.uhdResolution() || this.discResolution() || this.formatResolution();
  }

  uhdResolution() {
    const uhd = this.title.match(/\b(8K|4K|UHD)\b/i);
    if (!uhd) {
      return null;
    }
    return uhd[1].toUpperCase() === '8K' ? '8K' : '2160p';
  }

  discResolution() {
    const discMatch = this.title.match(
      /\b(DVD5|DVD9|DVD|BD25|BD50|BD66|BD100)\b/i,
    );
    return discMatch ? discMatch[1].toUpperCase() : null;
  }

  formatResolution() {
    const formatMatch =
      this.title.match(
        /\b(XviD|DivX|MP3|FLAC|OGG|AAC|WAV|APE|ALAC|WMA|OPUS|M4A)\b/i,
      ) || this.title.match(/\(?(МР3|МРЗ)\)?/i);
    if (!formatMatch) {
      return null;
    }
    const fmt = formatMatch[1].toLowerCase();
    return fmt === 'мр3' || fmt === 'мрз' ? 'mp3' : fmt;
  }

  extractSeason() {
    const seasonRangeMatch = this.title.match(/\bS(\d{1,2})[-–](\d{1,2})\b/i);
    if (seasonRangeMatch) {
      this.season = `Season ${Number.parseInt(seasonRangeMatch[1], 10)}-${Number.parseInt(seasonRangeMatch[2], 10)}`;
      return;
    }
    const seasonSingleMatch = this.title.match(/\bS(\d{1,2})(?:E\d+)?\b/i);
    this.season = seasonSingleMatch
      ? `Season ${Number.parseInt(seasonSingleMatch[1], 10)}`
      : null;
  }

  extractDateAndYear() {
    const fullDateMatch = this.title.match(/\(?(\d{2}\.\d{2}\.\d{4})\)?/);
    const shortDateMatch = this.title.match(/\(?(\d{2}\.\d{2}\.\d{2})\)?/);
    const dateMatch = fullDateMatch || shortDateMatch;
    this.date = dateMatch ? dateMatch[1] : null;

    const yearIntervalHyphenMatch = this.title.match(
      /\b((?:19|20)\d{2})\s*-\s*((?:19|20)\d{2})\b/,
    );
    if (yearIntervalHyphenMatch) {
      this.yearInterval = `${yearIntervalHyphenMatch[1]}-${yearIntervalHyphenMatch[2]}`;
    }

    this.year =
      fullDateMatch || this.yearInterval
        ? null
        : this.title.match(/\b(19\d{2}|20\d{2})\b/)?.[1] || null;
  }

  stripTechAndExtracted() {
    this.title = this.title.replaceAll(
      /(?:^|\.|\\s)Blu[\s-]*Ray(?:$|\\.|\\s)/gi,
      '',
    );
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
      if (tag === 'BluRay') {
        continue;
      }
      const escapedTag = escapeRegex(tag);
      this.title = this.title.replaceAll(
        new RegExp(`(?:^|\\.|\\s)${escapedTag}(?:$|\\.|\\s)`, 'gi'),
        ' ',
      );
    }
    this.title = this.title
      .replaceAll(/\.?#?\b(2160p|1080p|720p|480p|8K|4K|UHD)\b/gi, '')
      .replaceAll(/\.?#?\(?(DVD5|DVD9|DVD|BD25|BD50|BD66|BD100)\)?/gi, '')
      .replaceAll(
        /\.?#?\(?\b(XviD|DivX|MP3|FLAC|OGG|AAC|WAV|APE|ALAC|WMA|OPUS|M4A)\b\)?/gi,
        '',
      )
      .replaceAll(/\(?\(?(МР3|МРЗ)\)?/gi, '')
      .replaceAll(/\.?S\d{1,2}(?:[-–]\d{1,2})?(?:E\d+)?\b/gi, '');
    this.stripYearAndDate();
  }

  stripYearAndDate() {
    if (this.yearInterval) {
      this.title = this.title.replace(
        /\.?\(?(?:19|20)\d{2}\s*-\s*(?:19|20)\d{2}\)?/,
        '',
      );
      this.title = this.title.replaceAll(
        /(?:19|20)\d{2}(?:\.{2,}|\u2026)(?:19|20)\d{2}/g,
        '',
      );
      this.title = this.title.replaceAll(/\b(?:19|20)\d{2}\.{2,}/g, '');
    }
    if (this.year) {
      this.title = this.title.replace(/\.?\(?(19\d{2}|20\d{2})\)?/, '');
      this.title = this.title.replace(/^\. */, '');
    }
    this.title = this.title
      .replace(/\(?\d{2}\.\d{2}\.\d{4}\)?/, '')
      .replace(/\(?\d{2}\.\d{2}\.\d{2}\)?/, '');
  }

  normalizeRemainder() {
    const hasNoSpaces = !this.title.includes(' ');
    if (this.hadGluedDots || (hasNoSpaces && this.title.includes('.'))) {
      this.title = this.title.replaceAll('.', ' ');
    }
    this.title = this.title
      .replaceAll(' - ', '\u0000')
      .replaceAll(/(?:^|\s)-(?:\s|$)/g, ' ')
      .replaceAll('\u0000', ' - ')
      .replaceAll(/\s+/g, ' ')
      .trim();
    /* eslint-disable sonarjs/slow-regex -- simple patterns on short strings */
    this.title = this.title
      .replaceAll(/\. +\./g, '. ')
      .replaceAll(/ +\.(\w)/g, ' $1')
      .replaceAll(/ +\.$/g, '')
      .replaceAll(/ +\. /g, ' ')
      .replaceAll(/([^.])\.$/g, '$1')
      .trim();
    /* eslint-enable sonarjs/slow-regex */
    this.title = this.title
      .replaceAll(/\(\s*\)/g, '')
      .replaceAll(/\(\s*(?:HD|SD)\s*\)/gi, '');
    this.title = trimEdgeHyphens(this.title);
  }

  assemble() {
    let result = this.title;
    if (this.season) {
      result += ` - ${this.season}`;
    }
    if (this.yearInterval) {
      result += ` (${this.yearInterval})`;
    } else if (this.year && !this.date) {
      result += ` (${this.year})`;
    }
    if (this.date) {
      result += ` (${this.date})`;
    }
    if (this.resolution) {
      result += ` #${this.resolution}`;
    }
    return tightenParens(result);
  }
}

function splitFileExtension(name) {
  const lastDot = name.lastIndexOf('.');
  if (lastDot <= 0) {
    return { base: name, ext: '' };
  }
  const tail = name.slice(lastDot + 1);
  if (tail.length > 0 && tail.length <= 5 && /^[a-z0-9]+$/i.test(tail)) {
    return { base: name.slice(0, lastDot), ext: name.slice(lastDot) };
  }
  return { base: name, ext: '' };
}

function countSeparators(base) {
  const counts = { dot: 0, hyphen: 0, space: 0, underscore: 0 };
  for (const ch of base) {
    switch (ch) {
      case ' ': {
        counts.space += 1;
        break;
      }
      case '.': {
        counts.dot += 1;
        break;
      }
      case '-': {
        counts.hyphen += 1;
        break;
      }
      case '_': {
        counts.underscore += 1;
        break;
      }
      // No default
    }
  }
  return counts;
}

function needsSeparatorReplace(counts) {
  const separatorCount = counts.dot + counts.hyphen + counts.underscore;
  const noSpaces = counts.space === 0;
  return (
    (separatorCount >= 3 && separatorCount > counts.space) ||
    (noSpaces &&
      (counts.underscore > 0 || counts.dot >= 2 || counts.hyphen >= 2))
  );
}

function replacementForFilenameChar(base, i, isLetter) {
  const c = base[i];
  const prev = i > 0 ? base[i - 1] : '';
  const next = i + 1 < base.length ? base[i + 1] : '';
  const betweenDigits = /\d/.test(prev) && /\d/.test(next);
  if (c === '_') {
    return ' ';
  }
  if (c === '.') {
    return betweenDigits ? '.' : ' ';
  }
  if (c !== '-') {
    return c;
  }
  const spacedDash = prev === ' ' && next === ' ';
  const isHyphenatedWord = isLetter.test(prev) && isLetter.test(next);
  return betweenDigits || spacedDash || isHyphenatedWord ? '-' : ' ';
}

function replaceFilenameSeparators(base) {
  let out = '';
  const isLetter = /\p{L}/u;
  for (let i = 0; i < base.length; i += 1) {
    out += replacementForFilenameChar(base, i, isLetter);
  }
  return out.replaceAll(/\s+/g, ' ').trim();
}

function formatHumanFileName(name) {
  if (!name) {
    return 'Unknown';
  }
  const prepared = tightenParens(normalizeSeparators(name));
  const { base, ext } = splitFileExtension(prepared);
  if (!needsSeparatorReplace(countSeparators(base))) {
    return prepared;
  }
  const out = replaceFilenameSeparators(base);
  return out ? `${out}${ext}` : prepared;
}

function matchEpisodePrefix(name) {
  const seMatch = name.match(/\bS(\d{1,2})[.\s]?E(\d{1,3})\b/i);
  if (seMatch) {
    return {
      matchEnd: seMatch.index + seMatch[0].length,
      prefix: `S${Number.parseInt(seMatch[1], 10)} E${Number.parseInt(seMatch[2], 10)}`,
      standalone: false,
    };
  }
  const altMatch = name.match(/\b(\d{1,2})x(\d{1,3})\b/i);
  if (altMatch) {
    return {
      matchEnd: altMatch.index + altMatch[0].length,
      prefix: `S${Number.parseInt(altMatch[1], 10)} E${Number.parseInt(altMatch[2], 10)}`,
      standalone: false,
    };
  }
  const episodeMatch = name.match(/\b(?:S?\d{1,2})?E(\d{1,3})\b/i);
  if (!episodeMatch) {
    return null;
  }
  return {
    matchEnd: 0,
    prefix: `E${Number.parseInt(episodeMatch[1], 10)}`,
    standalone: true,
  };
}

function stripEpisodeTags(title) {
  let out = title
    .replaceAll(/\b[a-z0-9]+-?rip\b/gi, '')
    .replaceAll(/\b[a-z0-9]+HD\b/gi, '')
    .replaceAll(/\b[a-z0-9]*-?SbR\b/gi, '');
  for (const tag of episodeTagsToStrip) {
    out = out.replaceAll(new RegExp(`\\b${tag}\\b`, 'gi'), '');
  }
  return out.replace(/\.[a-z0-9]{2,5}$/i, '');
}

function dropUnbalancedBrackets(title) {
  let out = '';
  let parenDepth = 0;
  let bracketDepth = 0;
  for (const ch of title) {
    switch (ch) {
      case '(': {
        parenDepth += 1;
        break;
      }
      case ')': {
        if (parenDepth <= 0) {
          continue;
        }
        parenDepth -= 1;
        break;
      }
      case '[': {
        bracketDepth += 1;
        break;
      }
      case ']': {
        if (bracketDepth <= 0) {
          continue;
        }
        bracketDepth -= 1;
        break;
      }
      // No default
    }
    out += ch;
  }
  return out;
}

function trimEpisodeEdges(title) {
  let out = title;
  while (out.startsWith('-') || out.startsWith(' ') || out.startsWith('.')) {
    out = out.slice(1);
  }
  while (out.endsWith('-') || out.endsWith(' ') || out.endsWith('.')) {
    out = out.slice(0, -1);
  }
  return out;
}

function dropTrailingMkv(title) {
  if (!title.toLowerCase().endsWith('mkv')) {
    return title;
  }
  return trimEpisodeEdges(title.slice(0, -3).trim());
}

function isRedundantEpisodeTitle(title, torrentName) {
  if (!torrentName) {
    return false;
  }
  /* eslint-disable sonarjs/slow-regex -- simple pattern on short string */
  const cleanTorrentName = HumanTitle.format(torrentName)
    .replaceAll(/\s*(- Season \d+|\(\d{4}\)|#\d+p|#\w+)/gi, '')
    .trim();
  if (title.toLowerCase() === cleanTorrentName.toLowerCase()) {
    return true;
  }
  const titleWithoutYear = title
    .replaceAll(/\s*\(?\b(19|20)\d{2}\b\)?/g, '')
    .trim();
  /* eslint-enable sonarjs/slow-regex */
  return titleWithoutYear.toLowerCase() === cleanTorrentName.toLowerCase();
}

function formatEpisodeTitle(name, torrentName) {
  if (!name) {
    return '';
  }
  const match = matchEpisodePrefix(name);
  if (!match) {
    return '';
  }
  if (match.standalone) {
    return match.prefix;
  }
  const remaining = name.slice(match.matchEnd).replace(/^[.\-\s]+/, '');
  if (!remaining) {
    return match.prefix;
  }
  let title = stripEpisodeTags(formatHumanFileName(remaining));
  title = dropUnbalancedBrackets(title.replaceAll(/[([]\s*[)\]]/g, ''));
  title = title.replaceAll('|', '');
  /* eslint-disable-next-line sonarjs/slow-regex -- simple pattern on short string */
  title = title.replaceAll(/\s+l\s+/g, ' ');
  title = dropTrailingMkv(
    trimEpisodeEdges(title.replaceAll(/\s+/g, ' ').trim()),
  );
  if (!title || title === 'Unknown' || title.length <= 1) {
    return match.prefix;
  }
  if (isRedundantEpisodeTitle(title, torrentName)) {
    return match.prefix;
  }
  return `${match.prefix} - ${title}`;
}
