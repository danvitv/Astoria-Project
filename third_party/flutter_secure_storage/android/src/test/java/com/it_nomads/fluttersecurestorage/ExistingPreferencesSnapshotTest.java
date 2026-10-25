package com.it_nomads.fluttersecurestorage;

import android.content.Context;
import android.content.ContextWrapper;

import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Map;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class ExistingPreferencesSnapshotTest {
    private Context context;
    private File file;

    @Before
    public void setUp() {
        Context application = RuntimeEnvironment.getApplication();
        context = new ContextWrapper(application) {
            @Override public android.content.SharedPreferences getSharedPreferences(String name, int mode) {
                throw new AssertionError("Framework preference reads are forbidden");
            }
        };
        File directory = new File(context.getApplicationInfo().dataDir, "shared_prefs");
        assertTrue(directory.isDirectory() || directory.mkdirs());
        file = new File(directory, "snapshot-test.xml");
    }

    private void write(String xml) throws Exception {
        Files.write(file.toPath(), xml.getBytes(StandardCharsets.UTF_8));
    }

    @Test
    public void ordinaryAndroidStringBooleanXmlIsReadWithoutEditsAndEscapesArePreserved() throws Exception {
        write("<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n"
                + "<map><string name=\"escaped&amp;key\">abc&amp;def&#10;</string>"
                + "<boolean name=\"ENCRYPTED_PREFERENCES_MIGRATED\" value=\"true\" /></map>");
        byte[] before = Files.readAllBytes(file.toPath());
        Map<String, ?> result = ExistingPreferencesSnapshot.read(context, "snapshot-test");
        assertEquals("abc&def\n", result.get("escaped&key"));
        assertEquals(Boolean.TRUE, result.get("ENCRYPTED_PREFERENCES_MIGRATED"));
        assertArrayEquals(before, Files.readAllBytes(file.toPath()));
    }

    @Test
    public void emptyValidMapIsDistinctFromCorruptOrUnknownXml() throws Exception {
        write("<map />");
        assertTrue(ExistingPreferencesSnapshot.read(context, "snapshot-test").isEmpty());
        for (String invalid : new String[]{"", "<map>", "<wrong />", "<map /><map />",
                "<map><int name=\"unknown\" value=\"1\" /></map>",
                "<map><string name=\"duplicate\">a</string><string name=\"duplicate\">b</string></map>",
                "<map><string name=\"nested\"><string /></string></map>",
                "<map><boolean name=\"bad\" value=\"TRUE\" /></map>"}) {
            write(invalid);
            byte[] before = Files.readAllBytes(file.toPath());
            assertThrows(Exception.class, () -> ExistingPreferencesSnapshot.read(context, "snapshot-test"));
            assertArrayEquals(before, Files.readAllBytes(file.toPath()));
        }
    }

    @Test
    public void dtdAndExternalEntityAreDeniedWithoutFollowingOrEditingThem() throws Exception {
        write("<!DOCTYPE map [<!ENTITY external SYSTEM 'file:///does-not-exist'>]>"
                + "<map><string name=\"key\">&external;</string></map>");
        byte[] before = Files.readAllBytes(file.toPath());
        assertThrows(Exception.class, () -> ExistingPreferencesSnapshot.read(context, "snapshot-test"));
        assertArrayEquals(before, Files.readAllBytes(file.toPath()));
    }

    @Test
    public void missingFilesAndPathTraversalNeverAllocateAnotherNamespace() {
        File missing = new File(file.getParentFile(), "missing-snapshot-test.xml");
        assertFalse(missing.exists());
        assertThrows(Exception.class, () -> ExistingPreferencesSnapshot.read(context, "missing-snapshot-test"));
        assertFalse(missing.exists());
        assertThrows(Exception.class, () -> ExistingPreferencesSnapshot.read(context, "../snapshot-test"));
        assertThrows(Exception.class, () -> ExistingPreferencesSnapshot.read(context, ""));
    }

    @Test
    public void immutableViewKeepsOriginalDescriptorAndDeniesSameLengthContentChanges() throws Exception {
        write("<map><string name=\"key\">abc</string></map>");
        ExistingPreferencesSnapshot snapshot = ExistingPreferencesSnapshot.open(context, "snapshot-test");
        try {
            assertEquals("abc", snapshot.values().get("key"));
            assertThrows(UnsupportedOperationException.class, () -> snapshot.values().clear());
            write("<map><string name=\"key\">xyz</string></map>");
            assertEquals("abc", snapshot.values().get("key"));
            assertThrows(Exception.class, snapshot::verifyUnchanged);
            // The denial must not restore the original file content.
            assertTrue(Files.readString(file.toPath()).contains("xyz"));
        } finally {
            snapshot.close();
        }
        assertThrows(Exception.class, snapshot::verifyUnchanged);
        assertThrows(Exception.class, snapshot::values);
    }

    @Test
    public void pathReplacementAndNewBackupAreDeniedWithoutRecovery() throws Exception {
        write("<map />");
        byte[] before = Files.readAllBytes(file.toPath());
        File heldOriginal = new File(file.getParentFile(), "snapshot-test-held.xml");
        try (ExistingPreferencesSnapshot snapshot = ExistingPreferencesSnapshot.open(context, "snapshot-test")) {
            Files.move(file.toPath(), heldOriginal.toPath());
            Files.write(file.toPath(), before);
            try {
                assertThrows(Exception.class, snapshot::verifyUnchanged);
                assertTrue(heldOriginal.isFile());
                assertArrayEquals(before, Files.readAllBytes(file.toPath()));
            } finally {
                Files.delete(file.toPath());
                Files.move(heldOriginal.toPath(), file.toPath());
            }
        }
        File backup = new File(file.getPath() + ".bak");
        try (ExistingPreferencesSnapshot snapshot = ExistingPreferencesSnapshot.open(context, "snapshot-test")) {
            Files.write(backup.toPath(), before);
            try {
                assertThrows(Exception.class, snapshot::verifyUnchanged);
                assertArrayEquals(before, Files.readAllBytes(file.toPath()));
                assertArrayEquals(before, Files.readAllBytes(backup.toPath()));
            } finally {
                Files.delete(backup.toPath());
            }
        }
    }

    @Test
    public void directorySymlinkToTheSameXmlIsDeniedWithoutRepair() throws Exception {
        write("<map><string name=\"key\">abc</string></map>");
        byte[] before = Files.readAllBytes(file.toPath());
        File directory = file.getParentFile();
        File moved = new File(directory.getParentFile(), "shared_prefs-held");
        try (ExistingPreferencesSnapshot snapshot = ExistingPreferencesSnapshot.open(context, "snapshot-test")) {
            Files.move(directory.toPath(), moved.toPath());
            try {
                Files.createSymbolicLink(directory.toPath(), moved.toPath());
                // The XML identity/content remain original; only its directory changed.
                assertArrayEquals(before, Files.readAllBytes(file.toPath()));
                assertThrows(Exception.class, snapshot::verifyUnchanged);
                assertTrue(Files.isSymbolicLink(directory.toPath()));
                assertArrayEquals(before, Files.readAllBytes(new File(moved, file.getName()).toPath()));
            } finally {
                Files.deleteIfExists(directory.toPath());
                Files.move(moved.toPath(), directory.toPath());
            }
        }
    }
}
