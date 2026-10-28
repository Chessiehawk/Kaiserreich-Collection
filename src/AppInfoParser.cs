// Reads Steam's appcache\appinfo.vdf (binary, v27/v28/v29 formats) and, for one app,
// lists every depot with its DLC app id and the branches that have a manifest for it.
// Used by src\build_versions.ps1 to work out which DLC exist on each old HOI4 branch.
using System; using System.IO; using System.Text; using System.Collections.Generic;
public static class AppInfoParser {
  static string[] table;
  static string ReadCStr(BinaryReader r) { var ms = new List<byte>(); byte c; while ((c = r.ReadByte()) != 0) ms.Add(c); return Encoding.UTF8.GetString(ms.ToArray()); }
  static string Key(BinaryReader r, bool v29) { return v29 ? table[r.ReadInt32()] : ReadCStr(r); }
  static Dictionary<string, object> ReadKV(BinaryReader r, bool v29) {
    var d = new Dictionary<string, object>();
    while (true) {
      byte t = r.ReadByte(); if (t == 0x08) break; string k = Key(r, v29);
      switch (t) {
        case 0x00: d[k] = ReadKV(r, v29); break;
        case 0x01: d[k] = ReadCStr(r); break;
        case 0x02: d[k] = r.ReadInt32(); break;
        case 0x03: d[k] = r.ReadSingle(); break;
        case 0x07: d[k] = r.ReadUInt64(); break;
        case 0x0A: d[k] = r.ReadInt64(); break;
        default: throw new Exception("unknown kv type " + t);
      }
    }
    return d;
  }
  // returns lines "branch|buildid"
  public static string Branches(string path, uint want) {
    var appd = App(path, want); if (appd == null) return "";
    var br = (Dictionary<string, object>)((Dictionary<string, object>)appd["depots"])["branches"]; var sb = new StringBuilder();
    foreach (var kv in br) { var b = kv.Value as Dictionary<string, object>; sb.AppendLine(kv.Key + "|" + (b != null && b.ContainsKey("buildid") ? b["buildid"].ToString() : "")); }
    return sb.ToString();
  }
  static Dictionary<string, object> App(string path, uint want) {
    using (var r = new BinaryReader(File.OpenRead(path))) {
      uint magic = r.ReadUInt32(); r.ReadUInt32();
      bool v29 = magic == 0x07564429, v28 = magic == 0x07564428;
      if (v29) { long off = r.ReadInt64(); long here = r.BaseStream.Position; r.BaseStream.Position = off; int n = r.ReadInt32(); table = new string[n]; for (int i = 0; i < n; i++) table[i] = ReadCStr(r); r.BaseStream.Position = here; }
      while (true) {
        uint app = r.ReadUInt32(); if (app == 0) break;
        uint size = r.ReadUInt32(); long next = r.BaseStream.Position + size;
        if (app != want) { r.BaseStream.Position = next; continue; }
        r.ReadUInt32(); r.ReadUInt32(); r.ReadUInt64(); r.ReadBytes(20); r.ReadUInt32(); if (v28 || v29) r.ReadBytes(20);
        var root = ReadKV(r, v29);
        return (Dictionary<string, object>)(root.ContainsKey("appinfo") ? root["appinfo"] : root);
      }
    }
    return null;
  }
  // returns lines "depotId|dlcAppId(or -)|branch,branch,..."
  public static string Depots(string path, uint want) {
    using (var r = new BinaryReader(File.OpenRead(path))) {
      uint magic = r.ReadUInt32(); r.ReadUInt32();
      bool v29 = magic == 0x07564429, v28 = magic == 0x07564428;
      if (v29) { long off = r.ReadInt64(); long here = r.BaseStream.Position; r.BaseStream.Position = off; int n = r.ReadInt32(); table = new string[n]; for (int i = 0; i < n; i++) table[i] = ReadCStr(r); r.BaseStream.Position = here; }
      while (true) {
        uint app = r.ReadUInt32(); if (app == 0) break;
        uint size = r.ReadUInt32(); long next = r.BaseStream.Position + size;
        if (app != want) { r.BaseStream.Position = next; continue; }
        r.ReadUInt32(); r.ReadUInt32(); r.ReadUInt64(); r.ReadBytes(20); r.ReadUInt32(); if (v28 || v29) r.ReadBytes(20);
        var root = ReadKV(r, v29);
        var appd = (Dictionary<string, object>)(root.ContainsKey("appinfo") ? root["appinfo"] : root);
        var depots = (Dictionary<string, object>)appd["depots"]; var sb = new StringBuilder();
        foreach (var kv in depots) {
          var d = kv.Value as Dictionary<string, object>; if (d == null) continue;
          string dlc = d.ContainsKey("dlcappid") ? d["dlcappid"].ToString() : "-";
          string br = ""; if (d.ContainsKey("manifests")) foreach (var m in (Dictionary<string, object>)d["manifests"]) br += m.Key + ",";
          sb.AppendLine(kv.Key + "|" + dlc + "|" + br.TrimEnd(','));
        }
        return sb.ToString();
      }
    }
    return "";
  }
}
