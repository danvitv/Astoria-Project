package com.it_nomads.fluttersecurestorage;

import android.content.Context;
import android.os.Build;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;
import android.util.Xml;

import org.xmlpull.v1.XmlPullParser;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.security.GeneralSecurityException;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

/** Reads the existing Android preference XML, without SharedPreferences recovery or cache. */
final class ExistingPreferencesSnapshot implements AutoCloseable {
    // Explicitly deny unusually large/unsupported backends instead of an
    // unbounded allocation while deciding whether recovery can read safely.
    private static final int MAX_XML_BYTES = 4 * 1024 * 1024;
    private final File directory;
    private final StructStat originalDirectoryStat;
    private final File file;
    private final File backup;
    private final FileInputStream stream;
    private final StructStat originalStat;
    private final byte[] originalBytes;
    private final Map<String, ?> values;
    private boolean closed;

    static Map<String, ?> read(Context context, String name) throws Exception {
        try (ExistingPreferencesSnapshot snapshot = open(context, name)) {
            snapshot.verifyUnchanged();
            return snapshot.values();
        }
    }

    static ExistingPreferencesSnapshot open(Context context, String name) throws Exception {
        if (name.isEmpty() || name.contains("/") || name.contains("\\")) throw unavailable();
        // ApplicationInfo is metadata: do not call getDataDir/getFilesDir or a
        // preferences-directory getter, which may ensure/create the directory.
        String dataDir = context.getApplicationInfo().dataDir;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && context.isDeviceProtectedStorage()) {
            dataDir = context.getApplicationInfo().deviceProtectedDataDir;
        }
        if (dataDir == null || dataDir.isEmpty() || !new File(dataDir).isAbsolute()) throw unavailable();
        File directory = new File(dataDir, "shared_prefs");
        StructStat directoryStat = Os.lstat(directory.getPath());
        if (!OsConstants.S_ISDIR(directoryStat.st_mode)) throw unavailable();
        File file = new File(directory, name + ".xml");
        File backup = new File(directory, name + ".xml.bak");
        StructStat expected = Os.lstat(file.getPath());
        if (!OsConstants.S_ISREG(expected.st_mode)) throw unavailable();
        requireNoBackup(backup);
        FileInputStream stream = new FileInputStream(file);
        try {
            return new ExistingPreferencesSnapshot(directory, directoryStat, file, backup, stream, expected);
        } catch (Exception | Error failure) {
            // Preserve the original read failure; close only the descriptor we
            // actually opened. Never repair/delete/replace the backing file.
            try {
                stream.close();
            } catch (IOException closeFailure) {
                failure.addSuppressed(closeFailure);
            }
            throw failure;
        }
    }

    private ExistingPreferencesSnapshot(File directory, StructStat directoryStat,
                                         File file, File backup, FileInputStream stream,
                                         StructStat expected) throws Exception {
        this.directory = directory;
        originalDirectoryStat = directoryStat;
        this.file = file;
        this.backup = backup;
        this.stream = stream;
        originalStat = Os.fstat(stream.getFD());
        requireSameFile(expected, originalStat);
        if (originalStat.st_size < 0 || originalStat.st_size > MAX_XML_BYTES) throw unavailable();
        originalBytes = readBytes(stream);
        values = parse(originalBytes);
        verifyUnchanged();
    }

    Map<String, ?> values() throws GeneralSecurityException {
        if (closed) throw unavailable();
        return values;
    }

    void verifyUnchanged() throws Exception {
        if (closed) throw unavailable();
        requireStableMetadata();
        stream.getChannel().position(0);
        if (!Arrays.equals(originalBytes, readBytes(stream))) throw unavailable();
        requireStableMetadata();
    }

    private void requireStableMetadata() throws Exception {
        requireSameDirectory(originalDirectoryStat, Os.lstat(directory.getPath()));
        requireNoBackup(backup);
        requireSameFile(originalStat, Os.fstat(stream.getFD()));
        requireSameFile(originalStat, Os.lstat(file.getPath()));
        requireSameDirectory(originalDirectoryStat, Os.lstat(directory.getPath()));
    }

    private static void requireSameDirectory(StructStat expected, StructStat actual) throws GeneralSecurityException {
        if (!OsConstants.S_ISDIR(actual.st_mode) || expected.st_dev != actual.st_dev
                || expected.st_ino != actual.st_ino) throw unavailable();
    }

    private static void requireSameFile(StructStat expected, StructStat actual) throws GeneralSecurityException {
        if (!OsConstants.S_ISREG(actual.st_mode) || expected.st_dev != actual.st_dev
                || expected.st_ino != actual.st_ino || expected.st_mode != actual.st_mode
                || expected.st_size != actual.st_size || expected.st_mtime != actual.st_mtime
                || expected.st_ctime != actual.st_ctime) throw unavailable();
    }

    private static void requireNoBackup(File backup) throws Exception {
        try {
            Os.lstat(backup.getPath());
        } catch (ErrnoException failure) {
            if (failure.errno == OsConstants.ENOENT) return;
            throw unavailable(); // Permission/I/O errors are uncertainty, not absence.
        }
        throw unavailable();
    }

    private static byte[] readBytes(FileInputStream stream) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int count;
        while ((count = stream.read(buffer)) != -1) {
            if (bytes.size() > MAX_XML_BYTES - count) throw unavailable();
            bytes.write(buffer, 0, count);
        }
        return bytes.toByteArray();
    }

    private static Map<String, ?> parse(byte[] bytes) throws Exception {
        Map<String, Object> values = new HashMap<>();
        try (ByteArrayInputStream stream = new ByteArrayInputStream(bytes)) {
            XmlPullParser parser = Xml.newPullParser();
            parser.setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false);
            parser.setInput(stream, "UTF-8");
            if (nextContent(parser) != XmlPullParser.START_TAG || !"map".equals(parser.getName())
                    || parser.getAttributeCount() != 0) throw unavailable();
            while (true) {
                int token = nextContent(parser);
                if (token == XmlPullParser.END_TAG && "map".equals(parser.getName())) break;
                if (token != XmlPullParser.START_TAG) throw unavailable();
                String type = parser.getName();
                String key = parser.getAttributeValue(null, "name");
                if (key == null || values.containsKey(key)) throw unavailable();
                Object value;
                if ("string".equals(type) && parser.getAttributeCount() == 1) {
                    StringBuilder text = new StringBuilder();
                    while (true) {
                        token = parser.nextToken();
                        if (token == XmlPullParser.END_TAG && "string".equals(parser.getName())) break;
                        if ((token != XmlPullParser.TEXT && token != XmlPullParser.CDSECT
                                && token != XmlPullParser.ENTITY_REF) || parser.getText() == null) throw unavailable();
                        text.append(parser.getText());
                    }
                    value = text.toString();
                } else if ("boolean".equals(type) && parser.getAttributeCount() == 2) {
                    String rawValue = parser.getAttributeValue(null, "value");
                    if (!"true".equals(rawValue) && !"false".equals(rawValue)) throw unavailable();
                    value = Boolean.valueOf(rawValue);
                    if (nextContent(parser) != XmlPullParser.END_TAG || !"boolean".equals(parser.getName())) {
                        throw unavailable();
                    }
                } else {
                    // This backend writes strings and booleans only; never guess
                    // how an unknown preference type should affect eligibility.
                    throw unavailable();
                }
                values.put(key, value);
            }
            if (nextContent(parser) != XmlPullParser.END_DOCUMENT) throw unavailable();
        }
        return Collections.unmodifiableMap(values);
    }

    @Override
    public void close() throws IOException {
        closed = true;
        stream.close();
    }

    private static int nextContent(XmlPullParser parser) throws Exception {
        while (true) {
            int token = parser.nextToken();
            if (token == XmlPullParser.COMMENT
                    || (token == XmlPullParser.TEXT && parser.isWhitespace())) continue;
            // DTDs, processing instructions, and out-of-root entities are denied.
            return token;
        }
    }

    private static GeneralSecurityException unavailable() {
        return new GeneralSecurityException("Existing secure storage is unavailable.");
    }
}
