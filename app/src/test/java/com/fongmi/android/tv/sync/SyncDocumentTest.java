package com.fongmi.android.tv.sync;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import org.junit.Test;
import java.util.Map;
import static org.junit.Assert.*;

public class SyncDocumentTest {
    private static final String KEY = SyncDocument.identity("history", "source", "site", "vod");
    private JsonObject value(long position) {
        JsonObject v = new JsonObject(); v.addProperty("positionMs", position); return v;
    }
    private SyncDocument document(long modified, long position, String device) {
        SyncDocument d = new SyncDocument(); d.epoch = "same";
        SyncDocument.Entry e = new SyncDocument.Entry(); e.kind = "history";
        e.modified = modified; e.value = value(position); e.device = device; d.records.put(KEY, e); return d;
    }
    @Test public void laterRewatchWinsEvenWithLowerPosition() {
        SyncDocument merged = SyncDocument.merge(document(100, 900, "tv"), document(200, 50, "phone"));
        assertEquals(50, merged.records.get(KEY).value.get("positionMs").getAsLong());
    }
    @Test public void actualWatchTimeWinsOverDelayedObservationTime() {
        SyncReplica tv = new SyncReplica(), phone = new SyncReplica();
        JsonObject old = value(900), recent = value(50);
        old.addProperty("watchedAt", 100); recent.addProperty("watchedAt", 200);
        tv.observe(Map.of(KEY, old), Map.of(KEY, "history"), "tv", 1000);
        phone.observe(Map.of(KEY, recent), Map.of(KEY, "history"), "phone", 900);
        tv.document.epoch = phone.document.epoch;
        assertEquals(50, SyncDocument.merge(tv.document, phone.document).records.get(KEY).value.get("positionMs").getAsLong());
    }
    @Test public void localEditsPreserveFutureClientFields() {
        SyncReplica replica = new SyncReplica(); SyncDocument remote = document(100, 10, "phone");
        remote.records.get(KEY).value.addProperty("iosFutureOption", "keep");
        replica.receive(remote); replica.setObserved(Map.of(KEY, value(10)));
        replica.observe(Map.of(KEY, value(20)), Map.of(KEY, "history"), "tv", 200);
        assertEquals("keep", replica.document.records.get(KEY).value.get("iosFutureOption").getAsString());
    }
    @Test public void deleteDoesNotResurrectFromOfflineDevice() {
        SyncDocument old = document(100, 900, "tv");
        SyncDocument deleted = document(200, 0, "phone");
        deleted.records.get(KEY).deleted = true; deleted.records.get(KEY).value = null;
        assertTrue(SyncDocument.merge(old, deleted).records.get(KEY).deleted);
        assertTrue(SyncDocument.merge(deleted, old).records.get(KEY).deleted);
    }
    @Test public void tieBreakIsCommutativeAndIdempotent() {
        SyncDocument a = document(100, 900, "a"), b = document(100, 50, "b");
        Gson gson = new Gson();
        assertEquals(gson.toJson(SyncDocument.merge(a, b)), gson.toJson(SyncDocument.merge(b, a)));
        assertEquals(gson.toJson(a), gson.toJson(SyncDocument.merge(a, a)));
    }
    @Test public void identityMatchesCrossPlatformUtf8Fixture() {
        assertEquals("9039481f690907dc08356d94c53835454fa5adc0e402964c9108e00c86a653d0", SyncDocument.identity("source", "0", "https://example.test/影视?a=1&b=2"));
    }
    @Test public void identityIsUnambiguousAndSourceScoped() {
        assertNotEquals(SyncDocument.identity("ab", "c"), SyncDocument.identity("a", "bc"));
        assertNotEquals(SyncDocument.identity("history", "sourceA", "s", "v"), SyncDocument.identity("history", "sourceB", "s", "v"));
        assertEquals(64, KEY.length());
    }
    @Test public void captureEmitsDeleteAndReAddWithHigherVersion() {
        SyncReplica replica = new SyncReplica();
        replica.observe(Map.of(KEY, value(10)), Map.of(KEY, "history"), "tv", 100);
        replica.observe(Map.of(), Map.of(), "tv", 200);
        assertTrue(replica.document.records.get(KEY).deleted);
        replica.observe(Map.of(KEY, value(5)), Map.of(KEY, "history"), "tv", 150);
        assertFalse(replica.document.records.get(KEY).deleted);
        assertTrue(replica.document.records.get(KEY).modified > 200);
    }
    @Test public void unchangedImportedValueIsNotANewLocalEdit() {
        SyncReplica replica = new SyncReplica();
        SyncDocument remote = document(500, 10, "phone");
        replica.receive(remote); replica.setObserved(Map.of(KEY, value(10)));
        replica.observe(Map.of(KEY, value(10)), Map.of(KEY, "history"), "tv", 1000);
        assertEquals(500, replica.document.records.get(KEY).modified);
        assertEquals("phone", replica.document.records.get(KEY).device);
    }
    @Test public void resetConsentSurvivesAnotherDeviceRebuilding() {
        SyncReplica replica = new SyncReplica();
        SyncDocument reset = new SyncDocument(); reset.mode = "reset"; reset.reset = "clear-1";
        assertTrue(replica.needsResetConsent(reset));
        SyncDocument rebuilt = new SyncDocument(); rebuilt.mode = "replace"; rebuilt.reset = reset.reset;
        assertTrue(replica.needsResetConsent(rebuilt));
        replica.acceptedReset = reset.reset;
        assertFalse(replica.needsResetConsent(rebuilt));
    }
    @Test public void unknownClientFieldsInsideRecordsSurviveMerge() {
        SyncDocument remote = document(100, 10, "phone");
        remote.records.get(KEY).value.addProperty("iosFutureOption", "keep");
        assertTrue(SyncDocument.merge(newEmpty("same"), remote).records.get(KEY).value.has("iosFutureOption"));
    }
    private SyncDocument newEmpty(String epoch) { SyncDocument d = new SyncDocument(); d.epoch = epoch; return d; }
    @Test(expected = IllegalArgumentException.class) public void missingSchemaIsRejected() { SyncDocument.parse("{}"); }
    @Test(expected = IllegalArgumentException.class) public void futureSchemaIsRejected() {
        SyncDocument d = newEmpty("same"); d.schema = 99; SyncDocument.parse(new Gson().toJson(d));
    }
    @Test(expected = IllegalArgumentException.class) public void differentEpochsCannotMerge() {
        SyncDocument.merge(newEmpty("old"), newEmpty("new"));
    }
}
