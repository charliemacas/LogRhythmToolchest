<#
.SYNOPSIS
    View, export and create LogRhythm .llx log message files.

.NOTES
    Name    : LLX-Tool.ps1
    Version : 1.1.1
    See docs/LLX-Tool.md (user guide) and docs/LLX-Tool-HANDOVER.md (technical design).

.DESCRIPTION
    A LogRhythm .llx file is a GZip-compressed .NET binary-serialised
    SC.Message.Export.LogMessageCollection (assembly scvbcomn):

      Collection : LicenseID, SubmittedBy, Comments, DateSubmitted
      Messages   : Hashtable of Guid -> SC.Message.Export.LogMessage
                   (Version, MsgSourceID, MsgSourceTypeID, MPERuleID,
                    Message, Comments, Status)

    Modes
      View         Show what's inside one or more .llx files
      Export       Write the log messages from .llx file(s) to .txt
      Compile      Turn a .txt file of logs into an .llx file
      BulkCompile  Turn every .txt file in a folder into its own .llx file

    The script reads and writes the binary format itself (MS-NRBF). It never calls
    BinaryFormatter, so it is safe on untrusted files and needs no LogRhythm DLLs.
    Runs on Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Mode
    View | Export | Compile | BulkCompile

.PARAMETER Path
    File(s), folder(s) or wildcards. View/Export take .llx; Compile takes .txt;
    BulkCompile takes a folder.

.PARAMETER OutputPath
    Export/Compile: output file (single input) or folder (several inputs).
    BulkCompile: output folder (default: next to each .txt).

.PARAMETER Recurse
    Include subfolders when Path is a folder. BulkCompile keeps the subfolder
    layout under OutputPath.

.PARAMETER Force
    Overwrite existing output files.

.PARAMETER TemplateLlx
    Compile/BulkCompile: copy LicenseID, SubmittedBy, MsgSourceID,
    MsgSourceTypeID, MPERuleID and the assembly version from an existing .llx
    produced by your LogRhythm deployment. Explicit parameters override it.

.PARAMETER LicenseID
    Compile/BulkCompile: LogRhythm licence ID written to the file header.

.PARAMETER SubmittedBy
    Compile/BulkCompile: submitter name in the file header. Default 'LogRhythm Administrator'.

.PARAMETER Comments
    Compile/BulkCompile: free-text comment in the file header.

.PARAMETER MsgSourceID
    Compile/BulkCompile: LogRhythm log source ID stamped on every message.

.PARAMETER MsgSourceTypeID
    Compile/BulkCompile: LogRhythm log source type ID stamped on every message.

.PARAMETER MPERuleID
    Compile/BulkCompile: MPE rule ID stamped on every message. Default -1 (unassigned),
    which is what LogRhythm writes.

.PARAMETER SplitMode
    Compile/BulkCompile: how a .txt is split into messages (ignored for .json input).
      Auto      (default) Windows <Event>...</Event> XML blocks if present,
                otherwise one message per non-blank line
      Line      one message per non-blank line
      BlankLine messages separated by one or more blank lines (multi-line logs)
      Regex     each match of -SplitPattern is one message

.PARAMETER JsonInput
    Compile/BulkCompile: (automatic for .json files) the input is a JSON array of records:
      [ { "Message": "<raw log>", "MsgSourceTypeID": 1000030, "MsgSourceID": 12, "MPERuleID": -1 }, ... ]
    Only Message is required; missing IDs fall back to the template/parameter values.
    Use this when one file holds logs from several log source types.

.PARAMETER SplitPattern
    Regex used when SplitMode is Regex.

.PARAMETER AssemblyVersion
    scvbcomn version written into the file. Default 7.25.0.1000.

.PARAMETER ExpandEventXml
    View: add EventID, Provider, Channel, Computer, TimeCreated, RecordID and
    EventData columns for Windows event XML messages.

.PARAMETER GridView
    View: open the messages in Out-GridView (Windows).

.PARAMETER Summary
    View: one summary line per file instead of the messages.

.PARAMETER Raw
    View: dump the full decoded object tree as JSON.

.PARAMETER Filter
    File pattern used when Path is a folder. Default *.llx (View/Export) or *.txt (Compile/BulkCompile).

.PARAMETER MaxDecompressedMB
    Safety limit on how large a single .llx may expand to in memory. Default 1024.

.EXAMPLE
    .\LLX-Tool.ps1 View .\export.llx

.EXAMPLE
    .\LLX-Tool.ps1 View .\export.llx -ExpandEventXml -GridView

.EXAMPLE
    .\LLX-Tool.ps1 Export .\export.llx                          # -> export.txt

.EXAMPLE
    .\LLX-Tool.ps1 Export D:\LLX -Recurse -OutputPath D:\TXT

.EXAMPLE
    .\LLX-Tool.ps1 Compile .\logs.txt -TemplateLlx .\export.llx

.EXAMPLE
    .\LLX-Tool.ps1 Compile .\logs.txt -MsgSourceTypeID <LogSourceTypeID> -LicenseID <LicenseID>

.EXAMPLE
    .\LLX-Tool.ps1 BulkCompile D:\Samples -Recurse -OutputPath D:\LLX -TemplateLlx .\export.llx
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('View', 'Export', 'Compile', 'BulkCompile')]
    [string]$Mode,

    [Parameter(Mandatory, Position = 1, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('FullName')]
    [string[]]$Path,

    [string]$OutputPath,
    [switch]$Recurse,
    [string]$Filter,
    [switch]$Force,

    # Compile
    [string]$TemplateLlx,
    [int]$LicenseID,
    [string]$SubmittedBy,
    [string]$Comments,
    [int]$MsgSourceID,
    [int]$MsgSourceTypeID,
    [int]$MPERuleID,
    [ValidateSet('Auto', 'Line', 'BlankLine', 'Regex')]
    [string]$SplitMode = 'Auto',
    [string]$SplitPattern,
    [switch]$JsonInput,
    [string]$AssemblyVersion,

    # View
    [switch]$ExpandEventXml,
    [switch]$GridView,
    [switch]$Summary,
    [switch]$Raw,

    [ValidateRange(1, 8192)]
    [int]$MaxDecompressedMB = 1024
)

begin {
    Set-StrictMode -Version 2.0
    # Per-file problems are reported with the caller's error preference (so -ErrorAction
    # SilentlyContinue / Stop work as expected); internal failures use Stop.
    $ReportEA = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'

    if ($SplitMode -eq 'Regex' -and -not $SplitPattern) { throw '-SplitPattern is required when -SplitMode is Regex.' }

    # ======================================================================
    # MS-NRBF reader + LLX writer (C# 5 syntax so it compiles on PS 5.1)
    # ======================================================================
    if (-not ('LlxTool.Nrbf' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.IO;
using System.IO.Compression;
using System.Text;

namespace LlxTool
{
    // ------------------------------------------------------------ reader

    public class NrbfObject { public int Id; public string TypeName; public OrderedDictionary Members = new OrderedDictionary(); }
    public class NrbfArray  { public int Id; public List<object> Items = new List<object>(); }
    public class NrbfRef    { public int Id; public NrbfRef(int id) { Id = id; } }
    class ClassInfo { public string Name; public string[] MemberNames; public byte[] BinaryTypes; public object[] AddInfo; }
    class NullRun   { public int Count; public NullRun(int c) { Count = c; } }

    public class ParseResult
    {
        public object Root;
        public bool Truncated;
        public string FirstLibrary;
    }

    public class Nrbf
    {
        readonly BinaryReader r;
        readonly Dictionary<int, object> objects = new Dictionary<int, object>();
        readonly Dictionary<int, ClassInfo> classes = new Dictionary<int, ClassInfo>();
        int rootId;
        bool sawEnd;
        string firstLib;
        int depth;
        long resolved;

        // Safety limits for hostile or corrupt input
        const int MaxDepth = 200;            // nesting of inline records
        const int MaxElements = 10000000;    // elements in any one array
        const int MaxMembers = 10000;        // members in any one class
        const long MaxResolvedNodes = 20000000;

        Nrbf(byte[] data) { r = new BinaryReader(new MemoryStream(data), Encoding.UTF8); }

        public static bool IsNrbf(byte[] b)
        {
            return b != null && b.Length >= 17 && b[0] == 0x00 &&
                   b[5] == 0xFF && b[6] == 0xFF && b[7] == 0xFF && b[8] == 0xFF &&
                   BitConverter.ToInt32(b, 9) == 1;
        }

        public static ParseResult Parse(byte[] data)
        {
            Nrbf p = new Nrbf(data);
            try { p.ReadAll(); } catch (EndOfStreamException) { }
            ParseResult res = new ParseResult();
            res.Truncated = !p.sawEnd;
            res.FirstLibrary = p.firstLib;
            object root;
            p.objects.TryGetValue(p.rootId, out root);
            res.Root = p.Resolve(root, new Dictionary<int, bool>(), 0);
            return res;
        }

        void ReadAll()
        {
            while (r.BaseStream.Position < r.BaseStream.Length)
            {
                byte rt = r.ReadByte();
                if (rt == 11) { sawEnd = true; return; }
                if (rt == 0) { rootId = r.ReadInt32(); r.ReadInt32(); r.ReadInt32(); r.ReadInt32(); continue; }
                ReadRecordBody(rt);
            }
        }

        object ReadRecord()
        {
            if (++depth > MaxDepth) throw new InvalidDataException("Object graph nested too deeply.");
            try { return ReadRecordBody(r.ReadByte()); }
            finally { depth--; }
        }

        static int CheckCount(long n, int max, string what)
        {
            if (n < 0 || n > max) throw new InvalidDataException(string.Format("Invalid {0} count {1}.", what, n));
            return (int)n;
        }

        object ReadRecordBody(byte rt)
        {
            switch (rt)
            {
                case 1: return ReadClassWithId();
                case 2: return ReadClass(true, false);
                case 3: return ReadClass(false, false);
                case 4: return ReadClass(true, true);
                case 5: return ReadClass(false, true);
                case 6: { int id = r.ReadInt32(); string s = r.ReadString(); objects[id] = s; return s; }
                case 7: return ReadBinaryArray();
                case 8: return ReadPrimitive(r.ReadByte());
                case 9: return new NrbfRef(r.ReadInt32());
                case 10: return null;
                case 12: { r.ReadInt32(); string lib = r.ReadString(); if (firstLib == null) firstLib = lib; return ReadRecord(); }
                case 13: return new NullRun(r.ReadByte());
                case 14: return new NullRun(r.ReadInt32());
                case 15: return ReadArraySinglePrimitive();
                case 16: case 17: return ReadArraySingle();
                default:
                    throw new InvalidDataException(string.Format("Unsupported NRBF record type {0} at offset 0x{1:X}", rt, r.BaseStream.Position - 1));
            }
        }

        object ReadClassWithId()
        {
            int id = r.ReadInt32();
            int metaId = r.ReadInt32();
            ClassInfo ci;
            if (!classes.TryGetValue(metaId, out ci)) throw new InvalidDataException("ClassWithId references unknown metadata " + metaId);
            return ReadMembers(id, ci);
        }

        object ReadClass(bool system, bool withTypes)
        {
            int id = r.ReadInt32();
            ClassInfo ci = new ClassInfo();
            ci.Name = r.ReadString();
            int n = CheckCount(r.ReadInt32(), MaxMembers, "member");
            ci.MemberNames = new string[n];
            for (int i = 0; i < n; i++) ci.MemberNames[i] = r.ReadString();
            if (withTypes)
            {
                ci.BinaryTypes = new byte[n];
                ci.AddInfo = new object[n];
                for (int i = 0; i < n; i++) ci.BinaryTypes[i] = r.ReadByte();
                for (int i = 0; i < n; i++) ci.AddInfo[i] = ReadAdditionalInfo(ci.BinaryTypes[i]);
            }
            if (!system) r.ReadInt32();
            classes[id] = ci;
            return ReadMembers(id, ci);
        }

        object ReadAdditionalInfo(byte bt)
        {
            switch (bt)
            {
                case 0: case 7: return r.ReadByte();
                case 3: return r.ReadString();
                case 4: { string n = r.ReadString(); r.ReadInt32(); return n; }
                default: return null;
            }
        }

        object ReadMembers(int id, ClassInfo ci)
        {
            NrbfObject o = new NrbfObject();
            o.Id = id; o.TypeName = ci.Name;
            objects[id] = o;
            for (int i = 0; i < ci.MemberNames.Length; i++)
            {
                object v = (ci.BinaryTypes != null && ci.BinaryTypes[i] == 0) ? ReadPrimitive((byte)ci.AddInfo[i]) : ReadRecord();
                o.Members[ci.MemberNames[i]] = v;
            }
            return o;
        }

        object ReadBinaryArray()
        {
            int id = r.ReadInt32();
            byte kind = r.ReadByte();
            int rank = CheckCount(r.ReadInt32(), 32, "array rank");
            long t = 1;
            for (int i = 0; i < rank; i++) { t *= CheckCount(r.ReadInt32(), MaxElements, "array length"); CheckCount(t, MaxElements, "array element"); }
            int total = (int)t;
            if (kind >= 3) for (int i = 0; i < rank; i++) r.ReadInt32();
            byte bt = r.ReadByte();
            object add = ReadAdditionalInfo(bt);
            NrbfArray a = new NrbfArray(); a.Id = id; objects[id] = a;
            if (bt == 0) { for (int i = 0; i < total; i++) a.Items.Add(ReadPrimitive((byte)add)); }
            else ReadElements(a, total);
            return a;
        }

        object ReadArraySinglePrimitive()
        {
            int id = r.ReadInt32(); int len = CheckCount(r.ReadInt32(), MaxElements, "array element"); byte pt = r.ReadByte();
            NrbfArray a = new NrbfArray(); a.Id = id; objects[id] = a;
            if (pt == 2) { a.Items.Add(r.ReadBytes(len)); return a; }
            for (int i = 0; i < len; i++) a.Items.Add(ReadPrimitive(pt));
            return a;
        }

        object ReadArraySingle()
        {
            int id = r.ReadInt32(); int len = CheckCount(r.ReadInt32(), MaxElements, "array element");
            NrbfArray a = new NrbfArray(); a.Id = id; objects[id] = a;
            ReadElements(a, len);
            return a;
        }

        void ReadElements(NrbfArray a, int total)
        {
            while (a.Items.Count < total)
            {
                object v = ReadRecord();
                NullRun nr = v as NullRun;
                if (nr != null)
                {
                    if (nr.Count < 0 || (long)a.Items.Count + nr.Count > total) throw new InvalidDataException("Null run overflows array.");
                    for (int k = 0; k < nr.Count; k++) a.Items.Add(null);
                }
                else a.Items.Add(v);
            }
        }

        object ReadPrimitive(byte t)
        {
            switch (t)
            {
                case 1: return r.ReadBoolean();
                case 2: return r.ReadByte();
                case 3: { byte b0 = r.ReadByte(); int n = b0 < 0x80 ? 0 : b0 < 0xE0 ? 1 : b0 < 0xF0 ? 2 : 3;
                          byte[] buf = new byte[n + 1]; buf[0] = b0; for (int i = 1; i <= n; i++) buf[i] = r.ReadByte();
                          return Encoding.UTF8.GetString(buf)[0]; }
                case 5: return decimal.Parse(r.ReadString(), System.Globalization.CultureInfo.InvariantCulture);
                case 6: return r.ReadDouble();
                case 7: return r.ReadInt16();
                case 8: return r.ReadInt32();
                case 9: return r.ReadInt64();
                case 10: return r.ReadSByte();
                case 11: return r.ReadSingle();
                case 12: return new TimeSpan(r.ReadInt64());
                case 13: return ToDateTime(r.ReadInt64());
                case 14: return r.ReadUInt16();
                case 15: return r.ReadUInt32();
                case 16: return r.ReadUInt64();
                case 17: return null;
                case 18: return r.ReadString();
                default: throw new InvalidDataException("Unknown primitive type " + t);
            }
        }

        static DateTime ToDateTime(long v)
        {
            long ticks = v & 0x3FFFFFFFFFFFFFFFL;
            int kind = (int)((ulong)v >> 62);
            if (ticks < DateTime.MinValue.Ticks || ticks > DateTime.MaxValue.Ticks) return DateTime.MinValue;
            return new DateTime(ticks, kind == 1 ? DateTimeKind.Utc : kind == 2 ? DateTimeKind.Local : DateTimeKind.Unspecified);
        }

        object Resolve(object v, Dictionary<int, bool> stack, int depth)
        {
            if (depth > 64) return "<max depth>";
            if (++resolved > MaxResolvedNodes) throw new InvalidDataException("Object graph too large.");
            NrbfRef rf = v as NrbfRef;
            if (rf != null) { object t; if (!objects.TryGetValue(rf.Id, out t)) return null; v = t; }

            NrbfArray arr = v as NrbfArray;
            if (arr != null)
            {
                if (stack.ContainsKey(arr.Id)) return "<cycle>";
                if (arr.Items.Count == 1 && arr.Items[0] is byte[]) return arr.Items[0];
                stack[arr.Id] = true;
                object[] o2 = new object[arr.Items.Count];
                for (int i = 0; i < o2.Length; i++) o2[i] = Resolve(arr.Items[i], stack, depth + 1);
                stack.Remove(arr.Id);
                return o2;
            }

            NrbfObject o = v as NrbfObject;
            if (o == null) return v;
            if (stack.ContainsKey(o.Id)) return "<cycle>";
            stack[o.Id] = true;
            try
            {
                if (o.TypeName == "System.Guid") return ToGuid(o);
                if (o.TypeName == "System.Collections.Hashtable")
                {
                    object[] ka = Resolve(o.Members["Keys"], stack, depth + 1) as object[];
                    object[] va = Resolve(o.Members["Values"], stack, depth + 1) as object[];
                    List<object> entries = new List<object>();
                    if (ka != null)
                        for (int i = 0; i < ka.Length; i++)
                        {
                            OrderedDictionary e = new OrderedDictionary();
                            e["Key"] = ka[i];
                            e["Value"] = (va != null && i < va.Length) ? va[i] : null;
                            entries.Add(e);
                        }
                    OrderedDictionary h = new OrderedDictionary();
                    h["__type"] = o.TypeName;
                    h["__entries"] = entries.ToArray();
                    return h;
                }
                OrderedDictionary d = new OrderedDictionary();
                d["__type"] = o.TypeName;
                foreach (DictionaryEntry m in o.Members) d[(string)m.Key] = Resolve(m.Value, stack, depth + 1);
                return d;
            }
            finally { stack.Remove(o.Id); }
        }

        static Guid ToGuid(NrbfObject o)
        {
            try
            {
                return new Guid(Convert.ToInt32(o.Members["_a"]), Convert.ToInt16(o.Members["_b"]), Convert.ToInt16(o.Members["_c"]),
                    Convert.ToByte(o.Members["_d"]), Convert.ToByte(o.Members["_e"]), Convert.ToByte(o.Members["_f"]),
                    Convert.ToByte(o.Members["_g"]), Convert.ToByte(o.Members["_h"]), Convert.ToByte(o.Members["_i"]),
                    Convert.ToByte(o.Members["_j"]), Convert.ToByte(o.Members["_k"]));
            }
            catch { return Guid.Empty; }
        }
    }

    public static class Gz
    {
        public static byte[] Expand(byte[] data, long maxBytes)
        {
            if (data.Length < 2 || data[0] != 0x1F || data[1] != 0x8B) return data;
            using (MemoryStream input = new MemoryStream(data))
            using (GZipStream gz = new GZipStream(input, CompressionMode.Decompress))
            using (MemoryStream output = new MemoryStream())
            {
                byte[] buf = new byte[81920];
                int n;
                while ((n = gz.Read(buf, 0, buf.Length)) > 0)
                {
                    if (output.Length + n > maxBytes)
                        throw new InvalidDataException("File expands beyond the -MaxDecompressedMB limit.");
                    output.Write(buf, 0, n);
                }
                return output.ToArray();
            }
        }
    }

    // ------------------------------------------------------------ writer

    public class LlxMessage
    {
        public Guid Id = Guid.NewGuid();
        public int Version = 1;
        public int MsgSourceID;
        public int MsgSourceTypeID;
        public int MPERuleID = -1;
        public string Message = "";
        public string Comments = "";
        public int Status = 0;
    }

    public static class LlxWriter
    {
        public static List<LlxMessage> FromLines(IList<object> lines, int msgSourceId, int msgSourceTypeId, int mpeRuleId)
        {
            List<LlxMessage> list = new List<LlxMessage>(lines.Count);
            foreach (object l in lines)
            {
                LlxMessage m = new LlxMessage();
                m.MsgSourceID = msgSourceId; m.MsgSourceTypeID = msgSourceTypeId; m.MPERuleID = mpeRuleId;
                m.Message = Convert.ToString(l);
                list.Add(m);
            }
            return list;
        }

        // Same layout BinaryFormatter produces for LogRhythm's LogMessageCollection.
        public static byte[] BuildPayload(string assembly, int licenseId, string submittedBy, string comments,
                                          DateTime submittedUtc, IList<LlxMessage> msgs)
        {
            int n = msgs.Count;
            MemoryStream ms = new MemoryStream();
            BinaryWriter w = new BinaryWriter(ms, new UTF8Encoding(false));
            Dictionary<string, int> strings = new Dictionary<string, int>(StringComparer.Ordinal);
            int nextId = 8 + 2 * n;   // ids 1-7 fixed, then n Guids, then n messages, then strings

            // header + library
            w.Write((byte)0); w.Write(1); w.Write(-1); w.Write(1); w.Write(0);
            w.Write((byte)12); w.Write(2); w.Write(assembly);

            // LogMessageCollection (id 1)
            w.Write((byte)5); w.Write(1); w.Write("SC.Message.Export.LogMessageCollection");
            w.Write(5);
            w.Write("MsgsHashtable"); w.Write("LicenseID"); w.Write("SubmittedBy"); w.Write("Comments"); w.Write("DateSubmitted");
            w.Write(new byte[] { 3, 0, 1, 1, 0 });
            w.Write("System.Collections.Hashtable"); w.Write((byte)8); w.Write((byte)13);
            w.Write(2);
            w.Write((byte)9); w.Write(3);
            w.Write(licenseId);
            int sid = 4;
            WriteStr(w, submittedBy, strings, ref sid);
            WriteStr(w, comments, strings, ref sid);
            DateTime utc = submittedUtc.Kind == DateTimeKind.Utc ? submittedUtc : submittedUtc.ToUniversalTime();
            w.Write(utc.Ticks | 0x4000000000000000L);

            // Hashtable (id 3)
            int hashSize, version;
            HashtableSizing(n, out hashSize, out version);
            w.Write((byte)4); w.Write(3); w.Write("System.Collections.Hashtable");
            w.Write(7);
            w.Write("LoadFactor"); w.Write("Version"); w.Write("Comparer"); w.Write("HashCodeProvider");
            w.Write("HashSize"); w.Write("Keys"); w.Write("Values");
            w.Write(new byte[] { 0, 0, 3, 3, 0, 5, 5 });
            w.Write((byte)11); w.Write((byte)8);
            w.Write("System.Collections.IComparer"); w.Write("System.Collections.IHashCodeProvider");
            w.Write((byte)8);
            w.Write(0.72f); w.Write(version);
            w.Write((byte)10); w.Write((byte)10);
            w.Write(hashSize);
            w.Write((byte)9); w.Write(6);
            w.Write((byte)9); w.Write(7);

            // Keys (id 6) and Values (id 7)
            w.Write((byte)16); w.Write(6); w.Write(n);
            for (int i = 0; i < n; i++) { w.Write((byte)9); w.Write(8 + i); }
            w.Write((byte)16); w.Write(7); w.Write(n);
            for (int i = 0; i < n; i++) { w.Write((byte)9); w.Write(8 + n + i); }

            // Guids
            for (int i = 0; i < n; i++)
            {
                if (i == 0)
                {
                    w.Write((byte)4); w.Write(8); w.Write("System.Guid");
                    w.Write(11);
                    foreach (string f in new string[] { "_a", "_b", "_c", "_d", "_e", "_f", "_g", "_h", "_i", "_j", "_k" }) w.Write(f);
                    w.Write(new byte[11]);
                    w.Write(new byte[] { 8, 7, 7, 2, 2, 2, 2, 2, 2, 2, 2 });
                }
                else { w.Write((byte)1); w.Write(8 + i); w.Write(8); }
                w.Write(msgs[i].Id.ToByteArray());
            }

            // LogMessages
            int firstMsg = 8 + n;
            sid = nextId;
            for (int i = 0; i < n; i++)
            {
                LlxMessage m = msgs[i];
                if (i == 0)
                {
                    w.Write((byte)5); w.Write(firstMsg); w.Write("SC.Message.Export.LogMessage");
                    w.Write(7);
                    w.Write("Version"); w.Write("MsgSourceID"); w.Write("MsgSourceTypeID"); w.Write("MPERuleID");
                    w.Write("Message"); w.Write("Comments"); w.Write("Status");
                    w.Write(new byte[] { 0, 0, 0, 0, 1, 1, 0 });
                    w.Write(new byte[] { 8, 8, 8, 8, 8 });
                    w.Write(2);
                }
                else { w.Write((byte)1); w.Write(firstMsg + i); w.Write(firstMsg); }
                w.Write(m.Version); w.Write(m.MsgSourceID); w.Write(m.MsgSourceTypeID); w.Write(m.MPERuleID);
                WriteStr(w, m.Message, strings, ref sid);
                WriteStr(w, m.Comments, strings, ref sid);
                w.Write(m.Status);
            }

            w.Write((byte)11);
            w.Flush();
            return ms.ToArray();
        }

        static void WriteStr(BinaryWriter w, string s, Dictionary<string, int> seen, ref int nextId)
        {
            if (s == null) { w.Write((byte)10); return; }
            int id;
            if (seen.TryGetValue(s, out id)) { w.Write((byte)9); w.Write(id); return; }
            id = nextId++;
            seen[s] = id;
            w.Write((byte)6); w.Write(id); w.Write(s);
        }

        // Mirrors how a default System.Collections.Hashtable grows, so HashSize/Version
        // match what LogRhythm itself would serialise.
        static readonly int[] Primes = {
            3, 7, 11, 17, 23, 29, 37, 47, 59, 71, 89, 107, 131, 163, 197, 239, 293, 353, 431, 521, 631, 761, 919,
            1103, 1327, 1597, 1931, 2333, 2801, 3371, 4049, 4861, 5839, 7013, 8419, 10103, 12143, 14591,
            17519, 21023, 25229, 30293, 36353, 43627, 52361, 62851, 75431, 90523, 108631, 130363, 156437,
            187751, 225307, 270371, 324449, 389357, 467237, 560689, 672827, 807403, 968897, 1162687, 1395263,
            1674319, 2009191, 2411033, 2893249, 3471899, 4166287, 4999559, 5999471, 7199369 };

        static bool IsPrime(int c)
        {
            if ((c & 1) == 0) return c == 2;
            int lim = (int)Math.Sqrt(c);
            for (int d = 3; d <= lim; d += 2) if (c % d == 0) return false;
            return true;
        }

        static int GetPrime(int min)
        {
            foreach (int p in Primes) if (p >= min) return p;
            for (int i = min | 1; i < int.MaxValue; i += 2) if (IsPrime(i) && ((i - 1) % 101 != 0)) return i;
            return min;
        }

        static void HashtableSizing(int count, out int hashSize, out int version)
        {
            hashSize = 3;
            int loadsize = (int)(0.72f * hashSize);
            version = 0;
            for (int c = 0; c < count; c++)
            {
                if (c >= loadsize)
                {
                    hashSize = GetPrime(2 * hashSize);
                    loadsize = (int)(0.72f * hashSize);
                    version++;
                }
                version++;
            }
        }

        // GZip with the original-filename field, as LogRhythm writes it.
        public static byte[] GZip(byte[] payload, string innerName, DateTime mtimeUtc)
        {
            MemoryStream ms = new MemoryStream();
            long unix = (long)(mtimeUtc.ToUniversalTime() - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            ms.Write(new byte[] { 0x1F, 0x8B, 8, string.IsNullOrEmpty(innerName) ? (byte)0 : (byte)8 }, 0, 4);
            ms.Write(BitConverter.GetBytes((uint)unix), 0, 4);
            ms.WriteByte(0); ms.WriteByte(0x0B);
            if (!string.IsNullOrEmpty(innerName))
            {
                byte[] nb = Encoding.GetEncoding(28591).GetBytes(innerName);
                ms.Write(nb, 0, nb.Length); ms.WriteByte(0);
            }
            using (DeflateStream ds = new DeflateStream(ms, CompressionLevel.Optimal, true))
                ds.Write(payload, 0, payload.Length);
            ms.Write(BitConverter.GetBytes(Crc32(payload)), 0, 4);
            ms.Write(BitConverter.GetBytes((uint)payload.Length), 0, 4);
            return ms.ToArray();
        }

        static uint[] crcTable;
        static uint Crc32(byte[] data)
        {
            if (crcTable == null)
            {
                uint[] t = new uint[256];
                for (uint i = 0; i < 256; i++)
                {
                    uint c = i;
                    for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
                    t[i] = c;
                }
                crcTable = t;
            }
            uint crc = 0xFFFFFFFFu;
            foreach (byte b in data) crc = crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
            return crc ^ 0xFFFFFFFFu;
        }
    }
}
'@
    }

    $DefaultAssemblyVersion = '7.25.0.1000'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $collected = New-Object System.Collections.Generic.List[object]
    $inputs = New-Object System.Collections.Generic.List[object]   # @{ File; Root }

    # ---------------------------------------------------------------- shared helpers

    function Expand-LlxBytes([byte[]]$Bytes) {
        return , ([LlxTool.Gz]::Expand($Bytes, [long]$MaxDecompressedMB * 1MB))
    }

    function New-SafeRegex([string]$Pattern) {
        # Timeout guards against runaway (catastrophic backtracking) patterns
        New-Object System.Text.RegularExpressions.Regex($Pattern, [System.Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(60))
    }

    function ConvertTo-SafeXml([string]$Text) {
        # No DTDs, no external entities, no resolver
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $sr = New-Object System.IO.StringReader($Text)
        $xr = [System.Xml.XmlReader]::Create($sr, $settings)
        try {
            $doc = New-Object System.Xml.XmlDocument
            $doc.XmlResolver = $null
            $doc.Load($xr)
            return $doc
        }
        finally { $xr.Dispose(); $sr.Dispose() }
    }

    function Get-ErrorText($Err) {
        $e = $Err.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        return $e.Message
    }

    function Get-Member2($dict, [string]$name) {
        if ($dict -is [System.Collections.Specialized.OrderedDictionary] -and $dict.Contains($name)) { return $dict[$name] }
        return $null
    }

    function Read-LlxFile([string]$FilePath) {
        # Returns @{ Header; Messages[]; Library; Truncated; Root }
        $bytes = Expand-LlxBytes ([System.IO.File]::ReadAllBytes($FilePath))
        if (-not [LlxTool.Nrbf]::IsNrbf($bytes)) { throw "Not an LLX file (no .NET serialisation stream found after decompression)." }
        $res = [LlxTool.Nrbf]::Parse($bytes)
        $root = $res.Root
        $type = Get-Member2 $root '__type'
        if ($type -notlike '*LogMessageCollection') { throw "Contains a serialised '$type', not a LogRhythm LogMessageCollection." }

        $msgs = @()
        $table = Get-Member2 $root 'MsgsHashtable'
        if ($table) {
            $msgs = @(foreach ($e in $table['__entries']) {
                    $m = $e['Value']
                    if ($m -isnot [System.Collections.Specialized.OrderedDictionary]) { $m = @{} }
                    [pscustomobject]@{
                        MessageGuid     = $e['Key']
                        Version         = $m['Version']
                        MsgSourceID     = $m['MsgSourceID']
                        MsgSourceTypeID = $m['MsgSourceTypeID']
                        MPERuleID       = $m['MPERuleID']
                        Status          = $m['Status']
                        Comments        = $m['Comments']
                        Message         = $m['Message']
                    }
                })
        }
        [pscustomobject]@{
            Header    = [pscustomobject]@{
                LicenseID     = Get-Member2 $root 'LicenseID'
                SubmittedBy   = Get-Member2 $root 'SubmittedBy'
                Comments      = Get-Member2 $root 'Comments'
                DateSubmitted = Get-Member2 $root 'DateSubmitted'
            }
            Messages  = $msgs
            Library   = $res.FirstLibrary
            Truncated = $res.Truncated
            Root      = $root
        }
    }

    function Resolve-InputFiles([string[]]$Items, [string]$Pattern) {
        foreach ($item in $Items) {
            if (Test-Path -LiteralPath $item -PathType Container) {
                Get-ChildItem -LiteralPath $item -Filter $Pattern -File -Recurse:$Recurse | ForEach-Object {
                    [pscustomobject]@{ File = $_; Base = (Resolve-Path -LiteralPath $item).ProviderPath }
                }
            }
            else {
                $found = @(Get-ChildItem -Path $item -File -ErrorAction SilentlyContinue)
                if (-not $found) { $found = @(Get-ChildItem -LiteralPath $item -File -ErrorAction SilentlyContinue) }
                if (-not $found) { Write-Error "Not found: $item" -ErrorAction $ReportEA; continue }
                foreach ($f in $found) { [pscustomobject]@{ File = $f; Base = $f.DirectoryName } }
            }
        }
    }

    function Get-OutputFile($InputInfo, [string]$NewExtension, [int]$InputCount) {
        $f = $InputInfo.File
        $name = [System.IO.Path]::GetFileNameWithoutExtension($f.Name) + $NewExtension
        if (-not $OutputPath) { return (Join-Path $f.DirectoryName $name) }
        $isDir = (Test-Path -LiteralPath $OutputPath -PathType Container) -or $InputCount -gt 1 -or
                 $Mode -eq 'BulkCompile' -or -not [System.IO.Path]::HasExtension($OutputPath)
        if (-not $isDir) { return $OutputPath }
        $rel = ''
        if ($Recurse -and $f.DirectoryName.Length -gt $InputInfo.Base.Length) {
            $rel = $f.DirectoryName.Substring($InputInfo.Base.Length).TrimStart('\', '/')
        }
        return (Join-Path (Join-Path $OutputPath $rel) $name)
    }

    function Save-Bytes([string]$Target, [byte[]]$Bytes) {
        if ((Test-Path -LiteralPath $Target) -and -not $Force) { throw "$Target already exists (use -Force to overwrite)." }
        $dir = Split-Path -Parent $Target
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Target)
        [System.IO.File]::WriteAllBytes($full, $Bytes)
        return $full
    }

    function ConvertFrom-TextBytes([byte[]]$Bytes) {
        if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return [System.Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3) }
        if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2) }
        if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return [System.Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $Bytes.Length - 2) }
        $sample = [Math]::Min($Bytes.Length, 8192); $odd = 0; $even = 0
        for ($i = 0; $i -lt $sample; $i++) { if ($Bytes[$i] -eq 0) { if ($i % 2) { $odd++ } else { $even++ } } }
        if ($sample -and $odd -gt $sample * 0.3) { return [System.Text.Encoding]::Unicode.GetString($Bytes) }
        if ($sample -and $even -gt $sample * 0.3) { return [System.Text.Encoding]::BigEndianUnicode.GetString($Bytes) }
        try { return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($Bytes) }
        catch { return [System.Text.Encoding]::GetEncoding(1252).GetString($Bytes) }
    }

    function Split-LogText([string]$Text) {
        $mode = $SplitMode
        if ($mode -eq 'Auto') {
            # Only treat as Windows event XML when an event starts a line; other formats (e.g. McAfee ePO) embed <Event> elements
            if ($Text -match '(?m)^\s*<Event[\s>]' -and $Text -match '</Event>') { $mode = 'Event' } else { $mode = 'Line' }
        }
        switch ($mode) {
            'Event' {
                foreach ($m in (New-SafeRegex '(?ms)^\s*<Event[\s>].*?</Event>').Matches($Text)) {
                    # LogRhythm stores event XML on one line
                    ($m.Value -replace '>\s+<', '><').Trim()
                }
            }
            'Line' { foreach ($l in [regex]::Split($Text, '\r?\n')) { $t = $l.TrimEnd(); if ($t.Trim()) { $t } } }
            'BlankLine' { [regex]::Split($Text, '(?:\r?\n[ \t]*){2,}') | ForEach-Object { $_.Trim("`r", "`n") } | Where-Object { $_.Trim() } }
            'Regex' { foreach ($m in (New-SafeRegex $SplitPattern).Matches($Text)) { if ($m.Value.Trim()) { $m.Value } } }
        }
    }

    function ConvertFrom-JsonRecords([string]$Text, $Settings) {
        # JSON array of { Message, MsgSourceTypeID?, MsgSourceID?, MPERuleID? } (property names case-insensitive)
        $data = $Text | ConvertFrom-Json
        $list = New-Object 'System.Collections.Generic.List[LlxTool.LlxMessage]'
        $i = 0
        foreach ($r in @($data)) {
            $i++
            if ($null -eq $r) { continue }
            $props = @{}
            foreach ($p in $r.PSObject.Properties) { $props[$p.Name.ToLowerInvariant()] = $p.Value }
            if (-not $props.ContainsKey('message') -or $null -eq $props['message'] -or "$($props['message'])" -eq '') {
                throw "Record $i has no Message."
            }
            $m = New-Object LlxTool.LlxMessage
            $m.Message = [string]$props['message']
            $m.MsgSourceTypeID = if ($props.ContainsKey('msgsourcetypeid') -and $null -ne $props['msgsourcetypeid']) { [int]$props['msgsourcetypeid'] } else { $Settings.MsgSourceTypeID }
            $m.MsgSourceID = if ($props.ContainsKey('msgsourceid') -and $null -ne $props['msgsourceid']) { [int]$props['msgsourceid'] } else { $Settings.MsgSourceID }
            $m.MPERuleID = if ($props.ContainsKey('mperuleid') -and $null -ne $props['mperuleid']) { [int]$props['mperuleid'] } else { $Settings.MPERuleID }
            $list.Add($m)
        }
        return , $list
    }

    function Get-EventXmlFields([string]$Message) {
        $out = [ordered]@{ EventID = $null; Provider = $null; Channel = $null; Computer = $null; TimeCreated = $null; RecordID = $null; EventData = $null }
        if (-not $Message -or $Message.TrimStart() -notlike '<Event*') { return $out }
        try {
            $x = ConvertTo-SafeXml $Message
            $ns = New-Object System.Xml.XmlNamespaceManager($x.NameTable)
            $ns.AddNamespace('e', 'http://schemas.microsoft.com/win/2004/08/events/event')
            $sel = { param($xp) $n = $x.SelectSingleNode($xp, $ns); if ($n) { $n.Value } }
            $out.EventID = & $sel '//e:System/e:EventID/text()'
            $out.Provider = & $sel '//e:System/e:Provider/@Name'
            $out.Channel = & $sel '//e:System/e:Channel/text()'
            $out.Computer = & $sel '//e:System/e:Computer/text()'
            $out.TimeCreated = & $sel '//e:System/e:TimeCreated/@SystemTime'
            $out.RecordID = & $sel '//e:System/e:EventRecordID/text()'
            $ed = $x.SelectSingleNode('//e:EventData', $ns)
            if ($ed) {
                $named = @($ed.SelectNodes('e:Data[@Name]', $ns))
                if ($named.Count) { $out.EventData = ($named | ForEach-Object { '{0}={1}' -f $_.Name, $_.InnerText }) -join '; ' }
                else { $out.EventData = $ed.InnerText.Trim() }
            }
        }
        catch { Write-Verbose "Event XML parse failed: $($_.Exception.Message)" }
        return $out
    }

    function ConvertTo-PSValue($v) {
        if ($v -is [System.Collections.Specialized.OrderedDictionary]) {
            $o = [ordered]@{}; foreach ($k in $v.Keys) { $o[$k] = ConvertTo-PSValue $v[$k] }; return [pscustomobject]$o
        }
        if ($v -is [object[]]) { return , @($v | ForEach-Object { ConvertTo-PSValue $_ }) }
        if ($v -is [DateTime]) { return $v.ToString('o') }
        if ($v -is [Guid]) { return $v.ToString() }
        return $v
    }

    # ---------------------------------------------------------------- compile settings

    $compileSettings = $null
    if ($Mode -in 'Compile', 'BulkCompile') {
        $s = [ordered]@{
            LicenseID = 0; SubmittedBy = 'LogRhythm Administrator'; Comments = ''
            MsgSourceID = 0; MsgSourceTypeID = 0; MPERuleID = -1
            Assembly = "scvbcomn, Version=$DefaultAssemblyVersion, Culture=neutral, PublicKeyToken=null"
        }
        if ($TemplateLlx) {
            $t = Read-LlxFile (Resolve-Path -LiteralPath $TemplateLlx).ProviderPath
            $s.LicenseID = [int]$t.Header.LicenseID
            if ($t.Header.SubmittedBy) { $s.SubmittedBy = $t.Header.SubmittedBy }
            if ($t.Library) { $s.Assembly = $t.Library }
            if ($t.Messages.Count) {
                $s.MsgSourceID = [int]$t.Messages[0].MsgSourceID
                $s.MsgSourceTypeID = [int]$t.Messages[0].MsgSourceTypeID
                $s.MPERuleID = [int]$t.Messages[0].MPERuleID
            }
            Write-Verbose "Template: LicenseID=$($s.LicenseID) MsgSourceID=$($s.MsgSourceID) MsgSourceTypeID=$($s.MsgSourceTypeID) Assembly=$($s.Assembly)"
        }
        foreach ($k in 'LicenseID', 'SubmittedBy', 'Comments', 'MsgSourceID', 'MsgSourceTypeID', 'MPERuleID') {
            if ($PSBoundParameters.ContainsKey($k)) { $s[$k] = $PSBoundParameters[$k] }
        }
        if ($AssemblyVersion) { $s.Assembly = "scvbcomn, Version=$AssemblyVersion, Culture=neutral, PublicKeyToken=null" }
        $allJson = $JsonInput -or ($Path -and @($Path | Where-Object { $_ -notlike '*.json' }).Count -eq 0)
        if (-not $allJson -and -not $TemplateLlx -and -not $PSBoundParameters.ContainsKey('MsgSourceTypeID')) {
            Write-Warning 'No -MsgSourceTypeID or -TemplateLlx given: messages will carry log source type 0. Set it so LogRhythm associates the logs with the right log source type.'
        }
        if (-not $TemplateLlx -and -not $PSBoundParameters.ContainsKey('LicenseID')) {
            Write-Warning 'No -LicenseID or -TemplateLlx given: LicenseID will be 0.'
        }
        $compileSettings = [pscustomobject]$s
    }
}

process {
    foreach ($p in $Path) { $inputs.Add($p) }
}

end {
    switch ($Mode) {

        # ------------------------------------------------------------------ VIEW
        'View' {
            $pattern = if ($Filter) { $Filter } else { '*.llx' }
            foreach ($in in @(Resolve-InputFiles $inputs $pattern)) {
                $f = $in.File
                try { $llx = Read-LlxFile $f.FullName }
                catch { Write-Error "$($f.Name): $(Get-ErrorText $_)" -ErrorAction $ReportEA; continue }
                if ($llx.Truncated) { Write-Warning "$($f.Name) is truncated or corrupt; showing what could be recovered." }

                if ($Raw) { $collected.Add([pscustomobject]@{ File = $f.Name; Data = (ConvertTo-PSValue $llx.Root) }); continue }

                $h = $llx.Header
                if ($Summary) {
                    $collected.Add([pscustomobject]@{
                            File = $f.FullName; LicenseID = $h.LicenseID; SubmittedBy = $h.SubmittedBy
                            DateSubmitted = $h.DateSubmitted; Comments = $h.Comments; Messages = $llx.Messages.Count
                            MsgSourceIDs = (($llx.Messages | ForEach-Object MsgSourceID | Sort-Object -Unique) -join ', ')
                            MsgSourceTypeIDs = (($llx.Messages | ForEach-Object MsgSourceTypeID | Sort-Object -Unique) -join ', ')
                            Assembly = $llx.Library
                        })
                    continue
                }

                if (-not $GridView) {
                    Write-Host ''
                    Write-Host ("{0}" -f $f.FullName) -ForegroundColor Cyan
                    Write-Host ("  LicenseID {0} | Submitted by {1} | {2:yyyy-MM-dd HH:mm:ss} UTC | {3} message(s){4}" -f
                        $h.LicenseID, $h.SubmittedBy, $h.DateSubmitted, $llx.Messages.Count,
                        $(if ($h.Comments) { " | Comments: $($h.Comments)" } else { '' })) -ForegroundColor DarkCyan
                }
                $i = 0
                foreach ($m in $llx.Messages) {
                    $i++
                    $rec = [ordered]@{ File = $f.Name; Index = $i; MsgSourceID = $m.MsgSourceID; MsgSourceTypeID = $m.MsgSourceTypeID; MPERuleID = $m.MPERuleID }
                    if ($ExpandEventXml) { $ev = Get-EventXmlFields $m.Message; foreach ($k in $ev.Keys) { $rec[$k] = $ev[$k] } }
                    $rec['Message'] = $m.Message
                    $rec['MessageGuid'] = $m.MessageGuid
                    $rec['Status'] = $m.Status
                    $rec['Comments'] = $m.Comments
                    $rec['LicenseID'] = $h.LicenseID
                    $rec['SubmittedBy'] = $h.SubmittedBy
                    $rec['DateSubmitted'] = $h.DateSubmitted
                    $o = [pscustomobject]$rec
                    $o.PSObject.TypeNames.Insert(0, 'LlxTool.Message')
                    $collected.Add($o)
                }
            }

            if ($Raw) { $collected | ConvertTo-Json -Depth 20; return }
            if ($Summary) { $collected; return }
            if ($GridView) {
                if (Get-Command Out-GridView -ErrorAction SilentlyContinue) { $collected | Out-GridView -Title 'LLX contents' -Wait; return }
                Write-Warning 'Out-GridView is not available on this system; showing results in the console.'
            }
            # Default console view: compact columns; full objects still go down the pipeline
            $show = 'Index', 'MsgSourceID', 'MsgSourceTypeID', 'MPERuleID'
            if ($ExpandEventXml) { $show += 'EventID', 'Computer' }
            $show += 'Message'
            Update-TypeData -TypeName 'LlxTool.Message' -DefaultDisplayPropertySet $show -Force -ErrorAction SilentlyContinue
            $collected
        }

        # ------------------------------------------------------------------ EXPORT
        'Export' {
            $pattern = if ($Filter) { $Filter } else { '*.llx' }
            $files = @(Resolve-InputFiles $inputs $pattern)
            foreach ($in in $files) {
                $f = $in.File
                try {
                    $llx = Read-LlxFile $f.FullName
                    if ($llx.Truncated) { Write-Warning "$($f.Name) is truncated or corrupt; exporting what could be recovered." }
                    $msgs = [string[]]@(foreach ($mm in $llx.Messages) { if ($null -eq $mm.Message) { '' } else { [string]$mm.Message } })
                    $multiLine = $false; foreach ($mm in $msgs) { if ($mm.IndexOf("`n") -ge 0 -or $mm.IndexOf("`r") -ge 0) { $multiLine = $true; break } }
                    $sep = if ($multiLine) { "`r`n`r`n" } else { "`r`n" }
                    $text = ($msgs -join $sep) + "`r`n"
                    $target = Get-OutputFile $in '.txt' $files.Count
                    $full = Save-Bytes $target ($utf8NoBom.GetBytes($text))
                    if ($multiLine) { Write-Warning "$($f.Name) has multi-line messages; they are separated by blank lines. Use -SplitMode BlankLine to recompile it." }
                    [pscustomobject]@{ Source = $f.FullName; Output = $full; Messages = $msgs.Count }
                }
                catch { Write-Error "$($f.Name): $(Get-ErrorText $_)" -ErrorAction $ReportEA }
            }
        }

        # ------------------------------------------------------------------ COMPILE / BULK
        { $_ -in 'Compile', 'BulkCompile' } {
            $pattern = if ($Filter) { $Filter } else { '*.txt' }
            if ($Mode -eq 'BulkCompile') {
                foreach ($p in $inputs) { if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw "BulkCompile expects a folder: $p" } }
            }
            $files = @(Resolve-InputFiles $inputs $pattern)
            if (-not $files) { Write-Warning "No $pattern files found."; return }
            $s = $compileSettings
            $ok = 0; $failed = 0

            foreach ($in in $files) {
                $f = $in.File
                try {
                    $text = ConvertFrom-TextBytes ([System.IO.File]::ReadAllBytes($f.FullName))
                    if ($JsonInput -or $f.Extension -eq '.json') {
                        $list = ConvertFrom-JsonRecords $text $s
                        if ($list.Count -eq 0) { Write-Warning "$($f.Name): no records found, skipped."; continue }
                    }
                    else {
                        $lines = @(Split-LogText $text)
                        if ($lines.Count -eq 0) { Write-Warning "$($f.Name): no log messages found, skipped."; continue }
                        $list = [LlxTool.LlxWriter]::FromLines([object[]]$lines, $s.MsgSourceID, $s.MsgSourceTypeID, $s.MPERuleID)
                    }

                    $now = [DateTime]::UtcNow
                    $payload = [LlxTool.LlxWriter]::BuildPayload($s.Assembly, $s.LicenseID, $s.SubmittedBy, $s.Comments, $now, $list)
                    $inner = 'SubmittedLogs_{0}_{1:yyyyMMdd}_{1:HHmmssff}.llx.txt' -f $s.LicenseID, $now
                    $gz = [LlxTool.LlxWriter]::GZip($payload, $inner, $now)

                    $target = Get-OutputFile $in '.llx' $files.Count
                    $full = Save-Bytes $target $gz

                    # Verify by reading it back
                    $check = [LlxTool.Nrbf]::Parse((Expand-LlxBytes ([System.IO.File]::ReadAllBytes($full))))
                    $n = @($check.Root['MsgsHashtable']['__entries']).Count
                    if ($check.Truncated -or $n -ne $list.Count) { throw "Verification failed for $full" }

                    $ok++
                    $types = (@($list | ForEach-Object { $_.MsgSourceTypeID } | Sort-Object -Unique) -join ', ')
                    [pscustomobject]@{ Source = $f.FullName; Output = $full; Messages = $list.Count; MsgSourceTypeID = $types; LicenseID = $s.LicenseID }
                }
                catch { $failed++; Write-Error "$($f.Name): $(Get-ErrorText $_)" -ErrorAction $ReportEA }
            }
            if ($Mode -eq 'BulkCompile') { Write-Host "Compiled $ok file(s)$(if ($failed) { ", $failed failed" })." }
        }
    }
}
