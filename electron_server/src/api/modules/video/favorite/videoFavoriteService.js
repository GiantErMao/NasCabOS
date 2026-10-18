class VideoFavoriteService {
  constructor(knexVideo) {
    this.knexVideo = knexVideo;
    this.tableName = 'video_favorite';
  }

  _getUid(user) {
    const uid = user && user.id ? Number(user.id) : 0;
    return uid > 0 ? uid : 0;
  }

  async _movieGroupIds(indexId) {
    const row = await this.knexVideo('video_index').where({ id: indexId }).first('id', 'path', 'media_type', 'movie_group_key').catch(() => null);
    if (!row || row.media_type !== 'movie' || !row.movie_group_key) return [indexId];
    const rows = await this.knexVideo('video_index')
      .where({ path: row.path, media_type: 'movie', movie_group_key: row.movie_group_key })
      .orderBy('movie_part_no', 'asc').orderBy('id', 'asc').select('id').catch(() => []);
    return rows.length > 0 ? rows.map(item => item.id) : [indexId];
  }

  async addFavorite(user, indexId) {
    const uid = this._getUid(user);
    const safeIndexId = Number(indexId) || 0;
    if (!uid || !safeIndexId) return { is_favorite: false };
    const groupIds = await this._movieGroupIds(safeIndexId);

    const insertRow = {
      uid,
      index_id: groupIds[0],
      create_time: this.knexVideo.fn.now(),
    };

    const q = this.knexVideo(this.tableName).insert(insertRow);
    if (typeof q.onConflict === 'function') {
      await q.onConflict(['uid', 'index_id']).ignore();
    } else {
      try {
        await q;
      } catch (_) {}
    }
    return { is_favorite: true };
  }

  async removeFavorite(user, indexId) {
    const uid = this._getUid(user);
    const safeIndexId = Number(indexId) || 0;
    if (!uid || !safeIndexId) return { is_favorite: false };
    const groupIds = await this._movieGroupIds(safeIndexId);

    await this.knexVideo(this.tableName)
      .where({ uid }).whereIn('index_id', groupIds)
      .del()
      .catch(() => {});
    return { is_favorite: false };
  }

  async getFavoriteIndexIdSet(user, indexIds) {
    const uid = this._getUid(user);
    const list = Array.isArray(indexIds) ? indexIds.map(v => Number(v) || 0).filter(v => v > 0) : [];
    if (!uid || list.length === 0) return new Set();

    const rows = await this.knexVideo(this.tableName)
      .where({ uid })
      .whereIn('index_id', list)
      .select('index_id')
      .catch(() => []);

    return new Set((rows || []).map(r => Number(r && r.index_id) || 0).filter(v => v > 0));
  }
}

module.exports = VideoFavoriteService;
