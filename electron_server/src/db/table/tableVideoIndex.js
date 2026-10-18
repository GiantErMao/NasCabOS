const knexUtil = require('../knexUtil');
const dbUtil = require('../dbUtil');
const Logger = require('../../utils/logger');
const { parseMoviePart } = require('../../workers/videoIndex/movieParts');

function _normalizeNfoNumberCandidate(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';

  const reverse1Pondo = raw.match(/^(\d{6}[-_]\d{2,4})[-_\s]?1pon(?:do)?$/i);
  const normalizedRaw = reverse1Pondo ? `1PONDO-${reverse1Pondo[1]}` : raw;
  const code = normalizedRaw
    .replace(/[\s_]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '')
    .toUpperCase();
  if (!code) return '';

  const parts = code.split('-');
  const prefix = parts.length >= 2 ? parts[0].toLowerCase() : (code.match(/^([A-Z]+)\d+$/) || [])[1]?.toLowerCase() || '';
  const lastNumber = Number(parts.length >= 2 ? parts[parts.length - 1] : (code.match(/(\d+)$/) || [])[1]);
  if (!prefix) return '';
  if (!Number.isFinite(lastNumber)) return '';
  if (new Set(['bd', 'bluray', 'dvd', 'hdr', 'jav', 'remux', 'uhd', 'web', 'webrip']).has(prefix)) return '';
  if (parts.length < 2 && !/^[A-Z]{1,8}\d{2,8}$/.test(code)) return '';
  return code;
}

function _extractNfoNumberFromText(value) {
  const text = String(value || '').trim();
  if (!text) return '';
  const patterns = [
    /(^|[^0-9a-z])((?:fc2[-_\s]?(?:ppv[-_\s]?)?\d{5,8}))(?=$|[^0-9a-z])/i,
    /(^|[^0-9a-z])((?:1pondo[-_\s]?\d{6}[-_]\d{2,4}))(?=$|[^0-9a-z])/i,
    /(^|[^0-9a-z])((?:\d{6}[-_]\d{2,4}[-_\s]?1pon(?:do)?))(?=$|[^0-9a-z])/i,
    /(^|[^0-9a-z])([a-z]{2,8}[-_\s]\d{2,6}(?:[-_]\d{1,3})?)(?:ch)?(?=$|[^0-9a-z])/i,
    /(^|[^0-9a-z])([a-z]{1,8}\d{2,8})(?=$|[^0-9a-z])/i,
  ];
  for (const pattern of patterns) {
    const match = pattern.exec(text);
    const code = _normalizeNfoNumberCandidate(match && match[2] ? match[2] : '');
    if (code) return code;
  }
  return _normalizeNfoNumberCandidate(text);
}

class tableVideoIndex {
  constructor() {
    this.tableName = 'video_index';
  }

  async createTable(connection = null) {
    const knex = connection && connection.knex ? connection.knex : knexUtil.getInstance(dbUtil.DB_PATHS.VIDEO_DB);
    const tableExists = await knex.schema.hasTable(this.tableName);
    if (!tableExists) {
      await knex.schema.createTable(this.tableName, table => {
        table.increments('id').primary();
        table.string('path').notNullable();
        table.string('filename').notNullable();
        table.string('filename_fl').defaultTo('');
        table.string('ext').defaultTo('');
        table.integer('is_file').notNullable().defaultTo(1);
        table.string('file_hash').defaultTo('');
        table.string('play_rel_path').defaultTo('');
        table.string('movie_group_key').notNullable().defaultTo('');
        table.integer('movie_part_no').notNullable().defaultTo(0);
        table.string('nfo_name').defaultTo('');
        table.string('nfo_name_fl').defaultTo('');
        table.string('nfo_number').defaultTo('');
        table.string('nfo_source').defaultTo('');
        table.string('media_type').defaultTo('');
        table.integer('season_count').notNullable().defaultTo(0);
        table.integer('episod_count').notNullable().defaultTo(0);
        table.integer('size').notNullable().defaultTo(0);
        table.integer('width').notNullable().defaultTo(0);
        table.integer('height').notNullable().defaultTo(0);
        table.integer('duration').notNullable().defaultTo(0);
        table.text('nfo_alias').defaultTo('');
        table.text('nfo_tags').defaultTo('');
        table.text('nfo_regions').defaultTo('');
        table.text('nfo_language').defaultTo('');
        table.string('nfo_imdb_id').defaultTo('');
        table.text('nfo_genres').defaultTo('');
        table.date('nfo_release_date');
        table.text('nfo_storyline').defaultTo('');
        table.float('nfo_score').notNullable().defaultTo(0);
        table.integer('nfo_year').notNullable().defaultTo(0);
        table.text('nfo_actor').defaultTo('');
        table.text('nfo_director').defaultTo('');
        table.text('poster_path').defaultTo(''); //海报路径
        table.text('fanart_path').defaultTo(''); //横版海报图路径
        table.text('logo_path').defaultTo(''); //logo图路径
        table.text('nfo_actor_json').defaultTo('[]');
        table.text('nfo_director_json').defaultTo('[]');
        table.integer('open_skip_start_sec').notNullable().defaultTo(0);
        table.integer('open_skip_end_sec').notNullable().defaultTo(0);
        table.integer('nfo_get_state').notNullable().defaultTo(0);
        table.integer('gen_subtitle_vtt').notNullable().defaultTo(0);
        table.integer('gen_tiny').notNullable().defaultTo(0);
        table.integer('episod_num').notNullable().defaultTo(0);
        table.timestamp('create_time').defaultTo(knex.fn.now());
        table.timestamp('view_time');
      });
      Logger.info(`✅ Table ${this.tableName} created`);
    } else {
      const result = await knex.raw(`PRAGMA table_info(${this.tableName})`).catch(() => []);
      const rows = Array.isArray(result) ? result : result?.rows || [];
      const colNames = new Set((rows || []).map(r => (r && r.name ? String(r.name) : '')).filter(Boolean));
      const addColumn = async (name, sqlType) => {
        if (colNames.has(name)) return;
        await knex.raw(`ALTER TABLE ${this.tableName} ADD COLUMN ${name} ${sqlType}`);
        Logger.info(`✅ Added ${name} column to table ${this.tableName}`);
      };
      await addColumn('play_rel_path', "TEXT DEFAULT ''");
      const needsMoviePartBackfill = !colNames.has('movie_group_key') || !colNames.has('movie_part_no');
      await addColumn('movie_group_key', "TEXT NOT NULL DEFAULT ''");
      await addColumn('movie_part_no', 'INTEGER NOT NULL DEFAULT 0');
      if (needsMoviePartBackfill) {
        const movies = await knex(this.tableName).where({ media_type: 'movie', is_file: 1 }).select('id', 'filename');
        for (const movie of movies) {
          const part = parseMoviePart(movie.filename);
          if (part) await knex(this.tableName).where({ id: movie.id }).update({ movie_group_key: part.key, movie_part_no: part.number });
        }
      }
      await addColumn('nfo_number', "TEXT DEFAULT ''");
      if (!colNames.has('nfo_source')) {
        await knex.transaction(async trx => {
          await trx.raw(`ALTER TABLE ${this.tableName} ADD COLUMN nfo_source TEXT DEFAULT ''`);
          await this.backfillNfoSource({ knex: trx });
        });
        Logger.info(`✅ Added nfo_source column to table ${this.tableName}`);
      }
      await addColumn('gen_subtitle_vtt', 'INTEGER NOT NULL DEFAULT 0');
    }
    await this.backfillNfoNumber({ knex });
  }

  async backfillNfoSource({ knex }) {
    const path = require('path');
    const { readAndParseNfo } = require('../../workers/videoIndex/nfoParser');
    const rows = await knex(this.tableName).whereIn('media_type', ['movie', 'bdmv', 'video_ts']).select('id', 'path', 'filename', 'media_type');
    let updated = 0;
    for (const row of rows) {
      const dir = row.media_type === 'movie' ? row.path : path.join(row.path, row.filename);
      const candidates = row.media_type === 'movie'
        ? [path.join(dir, `${path.parse(row.filename).name}.nfo`), path.join(dir, 'movie.nfo'), path.join(dir, `${path.basename(dir)}.nfo`)]
        : [path.join(dir, 'movie.nfo'), path.join(dir, `${row.filename}.nfo`)];
      for (const nfoPath of candidates) {
        const parsed = await readAndParseNfo(nfoPath);
        if (!parsed) continue;
        if (parsed.type === 'movie' && parsed.metadataSource === 'metatube') {
          await knex(this.tableName).where({ id: row.id }).update({ nfo_source: 'metatube' });
          updated++;
        }
        break;
      }
    }
    if (updated > 0) Logger.info(`✅ Backfilled ${updated} MetaTube source values in table ${this.tableName}`);
  }

  async backfillNfoNumber({ knex }) {
    const rows = await knex(this.tableName)
      .where(builder => {
        builder.whereNull('nfo_number').orWhere('nfo_number', '');
      })
      .where(builder => {
        builder.whereNotNull('nfo_alias').orWhereNotNull('nfo_tags');
      })
      .select('id', 'nfo_alias', 'nfo_tags')
      .limit(2000)
      .catch(() => []);
    let updated = 0;
    for (const row of rows || []) {
      const id = Number(row && row.id) || 0;
      if (!id) continue;
      const code = _extractNfoNumberFromText(row.nfo_alias) || _extractNfoNumberFromText(row.nfo_tags);
      if (!code) continue;
      const n = await knex(this.tableName)
        .where({ id })
        .update({ nfo_number: code })
        .catch(() => 0);
      if (n) updated += 1;
    }
    if (updated > 0) Logger.info(`✅ Backfilled ${updated} nfo_number values in table ${this.tableName}`);
  }

  async createIndexes(connection = null) {
    const knex = connection && connection.knex ? connection.knex : knexUtil.getInstance(dbUtil.DB_PATHS.VIDEO_DB);
    const existingIndexes = await knex.raw(`SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='${this.tableName}'`);
    const indexNames = Array.isArray(existingIndexes) ? existingIndexes.map(row => row.name) : (existingIndexes?.rows || []).map(row => row.name);

    const targetIndexes = [
      { columns: ['path', 'filename'], name: 'uidx_video_index_path_filename', unique: true },

      { columns: ['path', 'filename', 'media_type', 'create_time'], name: 'idx_video_index_path_filename_media_type_create_time', unique: false },
      { columns: ['path', 'filename', 'media_type', 'view_time'], name: 'idx_video_index_path_filename_media_type_view_time', unique: false },
      { columns: ['path', 'filename', 'media_type', 'nfo_regions'], name: 'idx_video_index_path_filename_media_type_nfo_regions', unique: false },
      { columns: ['path', 'filename', 'media_type', 'nfo_language'], name: 'idx_video_index_path_filename_media_type_nfo_language', unique: false },
      { columns: ['path', 'filename', 'media_type', 'nfo_genres'], name: 'idx_video_index_path_filename_media_type_nfo_genres', unique: false },
      { columns: ['path', 'filename', 'media_type', 'nfo_release_date'], name: 'idx_video_index_path_filename_media_type_nfo_release_date', unique: false },
      { columns: ['path', 'filename', 'media_type', 'nfo_score'], name: 'idx_video_index_path_filename_media_type_nfo_score', unique: false },
      { columns: ['path', 'filename', 'media_type', 'nfo_director'], name: 'idx_video_index_path_filename_media_type_nfo_director', unique: false },
      { columns: ['path', 'filename', 'media_type', 'nfo_actor'], name: 'idx_video_index_path_filename_media_type_nfo_actor', unique: false },
      { columns: ['nfo_number'], name: 'idx_video_index_nfo_number', unique: false },
      { columns: ['path', 'movie_group_key', 'movie_part_no'], name: 'idx_video_index_movie_parts', unique: false },
    ];

    for (const index of targetIndexes) {
      if (!indexNames.includes(index.name)) {
        await knex.schema.alterTable(this.tableName, table => {
          if (index.unique) {
            table.unique(index.columns, index.name);
          } else {
            table.index(index.columns, index.name);
          }
        });
        Logger.info(`✅ Created index ${index.name} on table ${this.tableName}`);
      }
    }

    await this.createTriggers({ knex });
  }

  async createTriggers(connection = null) {
    const knex = connection && connection.knex ? connection.knex : knexUtil.getInstance(dbUtil.DB_PATHS.VIDEO_DB);
    const triggers = [
      {
        name: 'trg_video_index_delete_video_index2key',
        sql: `
          CREATE TRIGGER trg_video_index_delete_video_index2key
          AFTER DELETE ON video_index
          FOR EACH ROW
          BEGIN
            DELETE FROM video_index2key WHERE index_id = OLD.id;
          END;
        `,
      },
      {
        name: 'trg_video_index_delete_video_favorite',
        sql: `
          CREATE TRIGGER trg_video_index_delete_video_favorite
          AFTER DELETE ON video_index
          FOR EACH ROW
          BEGIN
            DELETE FROM video_favorite WHERE index_id = OLD.id;
          END;
        `,
      },
    ];

    for (const t of triggers) {
      const existing = await knex.raw("SELECT name FROM sqlite_master WHERE type='trigger' AND name=?", [t.name]);
      const triggerExists = Array.isArray(existing) ? existing.length > 0 : (existing?.rows || []).length > 0;
      if (triggerExists) continue;
      await knex.raw(t.sql);
      Logger.info(`✅ Created trigger ${t.name} on table ${this.tableName}`);
    }
  }
}

module.exports = new tableVideoIndex();
