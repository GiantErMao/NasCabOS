'use strict';

const path = require('path');

// Only a terminal CD number is a movie part. Keep the directory in the
// database lookup so identically named movies in different folders stay apart.
function parseMoviePart(filename) {
  const stem = path.parse(String(filename || '')).name;
  const match = stem.match(/^(.+?)[._-]cd([1-9]\d{0,2})$/i);
  if (!match) return null;
  const titleStem = match[1].replace(/[._-]+$/, '');
  if (!titleStem) return null;
  return { key: titleStem.toLowerCase(), titleStem, number: Number(match[2]) };
}

// SQL alias is fixed by our callers, never user input.
function whereMovieRepresentative(query, alias = 'v') {
  query.whereNotExists(function () {
    this.select(1).from('video_index as sibling')
      .whereRaw(`sibling.media_type = 'movie' AND ${alias}.media_type = 'movie'`)
      .whereRaw(`sibling.path = ${alias}.path AND sibling.movie_group_key = ${alias}.movie_group_key`)
      .whereRaw(`${alias}.movie_group_key <> ''`)
      .whereRaw(`(sibling.movie_part_no < ${alias}.movie_part_no OR (sibling.movie_part_no = ${alias}.movie_part_no AND sibling.id < ${alias}.id))`);
  });
  return query;
}

async function indexIdsForMovieGroups(knex, rows) {
  const ids = new Set(rows.map(row => Number(row && row.id) || 0).filter(Boolean));
  const groups = new Map();
  for (const row of rows) {
    if (row && row.media_type === 'movie' && row.movie_group_key) {
      groups.set(`${row.path}\0${row.movie_group_key}`, { path: row.path, key: row.movie_group_key });
    }
  }
  if (groups.size === 0) return [...ids];
  const siblings = await knex('video_index')
    .where({ media_type: 'movie' })
    .andWhere(builder => {
      for (const group of groups.values()) {
        builder.orWhere(function () {
          this.where('path', group.path).andWhere('movie_group_key', group.key);
        });
      }
    })
    .select('id');
  for (const sibling of siblings) ids.add(Number(sibling.id));
  return [...ids];
}

module.exports = { parseMoviePart, whereMovieRepresentative, indexIdsForMovieGroups };
