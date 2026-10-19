package com.fongmi.android.tv.sync;

import androidx.media3.exoplayer.libass.LibassFontFile;
import org.junit.Test;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import static org.junit.Assert.*;

public class CompatFontTest {
    private byte[] font() {
        byte[] family = "字体家族".getBytes(StandardCharsets.UTF_16BE);
        byte[] preferred = "首选字体".getBytes(StandardCharsets.UTF_16BE);
        int strings = 6 + 24, tableSize = strings + family.length + preferred.length;
        ByteBuffer b = ByteBuffer.allocate(28 + tableSize).order(ByteOrder.BIG_ENDIAN);
        b.putInt(0x00010000).putShort((short) 1).putShort((short) 0).putInt(0);
        b.putInt(0x6E616D65).putInt(0).putInt(28).putInt(tableSize);
        b.putShort((short) 0).putShort((short) 2).putShort((short) strings);
        b.putShort((short) 3).putShort((short) 1).putShort((short) 0x0409).putShort((short) 1).putShort((short) family.length).putShort((short) 0);
        b.putShort((short) 3).putShort((short) 1).putShort((short) 0x0409).putShort((short) 16).putShort((short) preferred.length).putShort((short) family.length);
        b.put(family).put(preferred); return b.array();
    }
    private String read(byte[] bytes) throws Exception {
        Path path = Files.createTempFile("font-fixture", ".ttf");
        try { Files.write(path, bytes); return LibassFontFile.getFamilyName(path.toFile()); }
        finally { Files.delete(path); }
    }
    @Test public void readsUnicodeAndChecksAllNameRecords() throws Exception { assertEquals("首选字体", read(font())); }
    @Test public void readsFirstFaceOfCollection() throws Exception {
        byte[] font = font();
        ByteBuffer.wrap(font).order(ByteOrder.BIG_ENDIAN).putInt(20, 44);
        ByteBuffer collection = ByteBuffer.allocate(font.length + 16).order(ByteOrder.BIG_ENDIAN);
        collection.putInt(0x74746366).putInt(0x00010000).putInt(1).putInt(16).put(font);
        assertEquals("首选字体", read(collection.array()));
    }
    @Test public void rejectsInvalidTableBounds() throws Exception {
        byte[] font = font(); ByteBuffer.wrap(font).order(ByteOrder.BIG_ENDIAN).putInt(20, Integer.MAX_VALUE);
        assertNull(read(font));
    }
    @Test public void rejectsUnrelatedFile() throws Exception { assertNull(read(new byte[16])); }
}
