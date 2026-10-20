package com.fongmi.android.tv.db.dao;

import androidx.room.Dao;
import androidx.room.Query;
import com.fongmi.android.tv.bean.EpisodeProgressRecord;
import java.util.List;

@Dao
public abstract class EpisodeProgressDao extends BaseDao<EpisodeProgressRecord> {
    @Query("SELECT * FROM EpisodeProgressRecord") public abstract List<EpisodeProgressRecord> findAll();
    @Query("SELECT * FROM EpisodeProgressRecord WHERE `key` = :key") public abstract EpisodeProgressRecord find(String key);
    @Query("DELETE FROM EpisodeProgressRecord WHERE `key` = :key") public abstract void delete(String key);
}
