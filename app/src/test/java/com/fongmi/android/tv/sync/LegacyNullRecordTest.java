package com.fongmi.android.tv.sync;
import org.junit.Test;
import static org.junit.Assert.*;
public class LegacyNullRecordTest {
    @Test public void deletedNullValueCanBeReadFromLegacyAndCurrentWireLayout() {
        String key=SyncDocument.identity("deleted-synthetic");
        String legacy="{\"a\":\"79d52d04-03e3-4ab4-b7bb-061c1aa0bf89\",\"b\":\"merge\",\"c\":\"\",\"d\":{\""+key+"\":{\"a\":\"history\",\"b\":100,\"c\":1,\"d\":\"synthetic\",\"e\":true,\"f\":null}}}";
        SyncDocument old=SyncDocument.parse(legacy);
        assertTrue(old.records.get(key).deleted);
        assertNull(old.records.get(key).value);
        String current="{\"schema\":1,\"epoch\":\"test\",\"mode\":\"merge\",\"reset\":\"\",\"records\":{\""+key+"\":{\"kind\":\"history\",\"modified\":100,\"sequence\":1,\"device\":\"synthetic\",\"deleted\":true,\"value\":null}}}";
        assertTrue(SyncDocument.parse(current).records.get(key).deleted);
    }
}
