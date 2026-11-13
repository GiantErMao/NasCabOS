const knexUtil = require('../knexUtil');
const dbUtil = require('../dbUtil');
const Logger = require('../../utils/logger');

class tableWaitGenTiny {
  constructor() {
    this.tableName = 'wait_gen_tiny';
  }

  async createTable(connection = null) {
    const knex = connection && connection.knex ? connection.knex : knexUtil.getInstance(dbUtil.DB_PATHS.PHOTO_DB);
    const tableExists = await knex.schema.hasTable(this.tableName);
    if (!tableExists) {
      await knex.schema.createTable(this.tableName, table => {
        table.increments('id').primary();
        table.text('source_path').notNullable().unique();
        table.string('status').notNullable().defaultTo('pending');
        table.text('last_error').nullable();
        table.bigInteger('updated_at').notNullable().defaultTo(0);
      });
      Logger.info(`✅ Table ${this.tableName} created`);
      return;
    }

    // Upgrade databases created before queued thumbnail state was tracked.
    if (!(await knex.schema.hasColumn(this.tableName, 'status'))) {
      await knex.schema.alterTable(this.tableName, table => {
        table.string('status').notNullable().defaultTo('pending');
      });
    }
    if (!(await knex.schema.hasColumn(this.tableName, 'last_error'))) {
      await knex.schema.alterTable(this.tableName, table => {
        table.text('last_error').nullable();
      });
    }
    if (!(await knex.schema.hasColumn(this.tableName, 'updated_at'))) {
      await knex.schema.alterTable(this.tableName, table => {
        table.bigInteger('updated_at').notNullable().defaultTo(0);
      });
    }
  }

  async createIndexes() {}
}

const tableWaitGenTinyInstance = new tableWaitGenTiny();

module.exports = tableWaitGenTinyInstance;
