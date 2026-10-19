package androidx.media3.exoplayer.libass;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;

/** 兼容版直接读取 TTF/OTF/TTC 的名称表，不依赖缺少的 libass 字体接口。 */
public final class LibassFontFile {
    private LibassFontFile() { }
    public static String getFamilyName(File file) throws IOException {
        try (RandomAccessFile input = new RandomAccessFile(file, "r")) {
            if (input.length() < 12) return null;
            long offset = 0;
            int magic = input.readInt();
            if (magic == 0x74746366) {
                input.readInt();
                long count = Integer.toUnsignedLong(input.readInt());
                if (count == 0 || input.length() < 16) return null;
                offset = Integer.toUnsignedLong(input.readInt());
                if (offset + 12 > input.length()) return null;
                input.seek(offset); magic = input.readInt();
            }
            if (magic != 0x00010000 && magic != 0x4F54544F && magic != 0x74727565) return null;
            int tables = input.readUnsignedShort();
            if (offset + 12L + tables * 16L > input.length()) return null;
            long names = -1, nameLength = 0;
            for (int i = 0; i < tables; i++) {
                input.seek(offset + 12L + i * 16L);
                int tag = input.readInt(); input.readInt();
                long position = Integer.toUnsignedLong(input.readInt()), size = Integer.toUnsignedLong(input.readInt());
                if (tag == 0x6E616D65) { names = position; nameLength = size; break; }
            }
            if (names < 0 || nameLength < 6 || names + nameLength > input.length()) return null;
            input.seek(names + 2);
            int count = input.readUnsignedShort(), strings = input.readUnsignedShort();
            if (6L + count * 12L > nameLength) return null;
            String best = null; int score = Integer.MAX_VALUE;
            for (int i = 0; i < count; i++) {
                input.seek(names + 6L + i * 12L);
                int platform = input.readUnsignedShort(), encoding = input.readUnsignedShort(), language = input.readUnsignedShort();
                int name = input.readUnsignedShort(), length = input.readUnsignedShort(), relative = input.readUnsignedShort();
                if ((name != 1 && name != 16) || length == 0 || (long) strings + relative + length > nameLength) continue;
                Charset charset;
                if (platform == 0 || platform == 3) {
                    if (length % 2 != 0) continue;
                    charset = StandardCharsets.UTF_16BE;
                } else if (platform == 1 && encoding == 0) charset = Charset.isSupported("x-MacRoman") ? Charset.forName("x-MacRoman") : StandardCharsets.ISO_8859_1;
                else continue;
                int priority = (name == 16 ? 0 : 100) + (platform == 3 ? 0 : platform == 0 ? 10 : 20) + (language == 0x0409 ? 0 : 1);
                if (priority >= score) continue;
                input.seek(names + strings + relative);
                byte[] bytes = new byte[length]; input.readFully(bytes);
                String value = new String(bytes, charset).replace("\u0000", "").trim();
                if (!value.isEmpty()) { best = value; score = priority; }
            }
            return best;
        }
    }
}
