package com.dywu.whalepet.pet;

import android.util.Log;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.Charset;

/**
 * 持久化：JSON 落盘到应用私有目录（filesDir），原子替换写入避免掉电损坏。
 * 字段与 iOS 版 whalepet-save.json 同名，方便互通/排障。
 */
public final class PetStore {

    private static final String TAG = "WhalePetStore";
    private static final String FILE_NAME = "whalepet-save.json";

    public static final class SaveData {
        public PetVitals vitals = new PetVitals();
        public long lastTick = System.currentTimeMillis();
        public String petName = "小鲸";
        public int totalFeeds = 0;
        public int totalPets = 0;
        public long bornAt = System.currentTimeMillis();
    }

    private static PetStore instance;

    private final File file;
    private final SaveData data;

    public static synchronized PetStore get(File filesDir) {
        if (instance == null) instance = new PetStore(filesDir);
        return instance;
    }

    private PetStore(File dir) {
        file = new File(dir, FILE_NAME);
        data = load();
    }

    public SaveData data() {
        return data;
    }

    public synchronized void save(PetBrain brain) {
        data.vitals = brain.vitals;
        data.lastTick = brain.lastTick;
        persist();
    }

    public synchronized void recordFeed() {
        data.totalFeeds++;
        persist();
    }

    public synchronized void recordPet() {
        data.totalPets++;
        persist();
    }

    public synchronized void rename(String name) {
        if (name == null) return;
        String trimmed = name.trim();
        if (trimmed.isEmpty()) return;
        data.petName = trimmed.length() > 12 ? trimmed.substring(0, 12) : trimmed;
        persist();
    }

    private SaveData load() {
        SaveData out = new SaveData();
        if (!file.isFile()) return out;
        try {
            String raw = new String(readAll(file), Charset.forName("UTF-8"));
            JSONObject o = new JSONObject(raw);
            JSONObject v = o.optJSONObject("vitals");
            if (v != null) {
                out.vitals.satiety = v.optDouble("satiety", 80);
                out.vitals.mood = v.optDouble("mood", 80);
                out.vitals.energy = v.optDouble("energy", 90);
                out.vitals.clamp();
            }
            out.lastTick = o.optLong("lastTick", System.currentTimeMillis());
            String n = o.optString("petName", "小鲸");
            if (!n.isEmpty()) out.petName = n;
            out.totalFeeds = o.optInt("totalFeeds", 0);
            out.totalPets = o.optInt("totalPets", 0);
            out.bornAt = o.optLong("bornAt", System.currentTimeMillis());
        } catch (Exception e) {
            Log.w(TAG, "存档解析失败，已回退到默认值: " + e.getMessage());
        }
        return out;
    }

    private void persist() {
        try {
            JSONObject o = new JSONObject();
            JSONObject v = new JSONObject();
            v.put("satiety", data.vitals.satiety);
            v.put("mood", data.vitals.mood);
            v.put("energy", data.vitals.energy);
            o.put("vitals", v);
            o.put("lastTick", data.lastTick);
            o.put("petName", data.petName);
            o.put("totalFeeds", data.totalFeeds);
            o.put("totalPets", data.totalPets);
            o.put("bornAt", data.bornAt);

            File tmp = new File(file.getAbsolutePath() + ".tmp");
            FileOutputStream fos = new FileOutputStream(tmp);
            try {
                fos.write(o.toString().getBytes(Charset.forName("UTF-8")));
                fos.flush();
                fos.getFD().sync();
            } finally {
                fos.close();
            }
            if (!tmp.renameTo(file)) {
                // 某些文件系统不支持覆盖式 rename，退化为直接写。
                FileOutputStream direct = new FileOutputStream(file);
                try {
                    direct.write(o.toString().getBytes(Charset.forName("UTF-8")));
                } finally {
                    direct.close();
                }
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        } catch (Exception e) {
            Log.w(TAG, "存档写入失败: " + e.getMessage());
        }
    }

    private static byte[] readAll(File f) throws IOException {
        FileInputStream in = new FileInputStream(f);
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return out.toByteArray();
        } finally {
            in.close();
        }
    }
}
