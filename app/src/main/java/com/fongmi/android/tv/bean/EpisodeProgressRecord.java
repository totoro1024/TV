package com.fongmi.android.tv.bean;

import androidx.annotation.NonNull;
import androidx.room.Entity;
import androidx.room.ForeignKey;
import androidx.room.Index;
import androidx.room.PrimaryKey;

@Entity(foreignKeys = @ForeignKey(entity = History.class, parentColumns = "key", childColumns = "historyKey", onDelete = ForeignKey.CASCADE), indices = @Index("historyKey"))
public class EpisodeProgressRecord {
    @PrimaryKey @NonNull public String key = "";
    @NonNull public String historyKey = "";
    @NonNull public String value = "";
}
