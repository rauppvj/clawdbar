using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace ClawdBar
{
    /// Minimal JSON reader/writer. Hand-rolled because the app is built with
    /// the in-box csc.exe, which has no package feed — a third-party JSON
    /// library would mean the user has to install an SDK first.
    internal sealed class JsonValue
    {
        public enum Kind { Null, Bool, Number, String, Array, Object }

        public Kind Type;
        public bool BoolValue;
        public double NumberValue;
        public string StringValue;
        public List<JsonValue> Items;
        public Dictionary<string, JsonValue> Members;

        public static JsonValue NewObject()
        {
            var v = new JsonValue();
            v.Type = Kind.Object;
            v.Members = new Dictionary<string, JsonValue>(StringComparer.Ordinal);
            return v;
        }

        public static JsonValue NewArray()
        {
            var v = new JsonValue();
            v.Type = Kind.Array;
            v.Items = new List<JsonValue>();
            return v;
        }

        public static JsonValue From(string s)
        {
            var v = new JsonValue();
            if (s == null) { v.Type = Kind.Null; return v; }
            v.Type = Kind.String;
            v.StringValue = s;
            return v;
        }

        public static JsonValue From(double d)
        {
            var v = new JsonValue();
            v.Type = Kind.Number;
            v.NumberValue = d;
            return v;
        }

        public static JsonValue From(bool b)
        {
            var v = new JsonValue();
            v.Type = Kind.Bool;
            v.BoolValue = b;
            return v;
        }

        /// Member lookup that returns null instead of throwing, so callers can
        /// chain optional fields without a pile of ContainsKey checks.
        public JsonValue this[string key]
        {
            get
            {
                if (Type != Kind.Object || Members == null) return null;
                JsonValue found;
                return Members.TryGetValue(key, out found) ? found : null;
            }
            set
            {
                if (Type != Kind.Object || Members == null) return;
                Members[key] = value;
            }
        }

        public string AsString(string fallback)
        {
            if (Type == Kind.String) return StringValue;
            if (Type == Kind.Number) return NumberValue.ToString(CultureInfo.InvariantCulture);
            if (Type == Kind.Bool) return BoolValue ? "true" : "false";
            return fallback;
        }

        public double AsDouble(double fallback)
        {
            if (Type == Kind.Number) return NumberValue;
            if (Type == Kind.String)
            {
                double parsed;
                if (double.TryParse(StringValue, NumberStyles.Float, CultureInfo.InvariantCulture, out parsed))
                    return parsed;
            }
            return fallback;
        }

        public bool AsBool(bool fallback)
        {
            if (Type == Kind.Bool) return BoolValue;
            if (Type == Kind.Number) return NumberValue != 0;
            return fallback;
        }

        public List<string> AsStringList()
        {
            var list = new List<string>();
            if (Type != Kind.Array || Items == null) return list;
            for (int i = 0; i < Items.Count; i++)
            {
                if (Items[i] != null && Items[i].Type == Kind.String) list.Add(Items[i].StringValue);
            }
            return list;
        }

        public string ToJson()
        {
            var sb = new StringBuilder();
            Write(sb, this);
            return sb.ToString();
        }

        private static void Write(StringBuilder sb, JsonValue v)
        {
            if (v == null) { sb.Append("null"); return; }
            switch (v.Type)
            {
                case Kind.Null:
                    sb.Append("null");
                    break;
                case Kind.Bool:
                    sb.Append(v.BoolValue ? "true" : "false");
                    break;
                case Kind.Number:
                    sb.Append(FormatNumber(v.NumberValue));
                    break;
                case Kind.String:
                    WriteString(sb, v.StringValue);
                    break;
                case Kind.Array:
                    sb.Append('[');
                    for (int i = 0; i < v.Items.Count; i++)
                    {
                        if (i > 0) sb.Append(',');
                        Write(sb, v.Items[i]);
                    }
                    sb.Append(']');
                    break;
                case Kind.Object:
                    sb.Append('{');
                    bool first = true;
                    foreach (var kv in v.Members)
                    {
                        if (!first) sb.Append(',');
                        first = false;
                        WriteString(sb, kv.Key);
                        sb.Append(':');
                        Write(sb, kv.Value);
                    }
                    sb.Append('}');
                    break;
            }
        }

        private static string FormatNumber(double d)
        {
            if (double.IsNaN(d) || double.IsInfinity(d)) return "0";
            if (d == Math.Floor(d) && Math.Abs(d) < 1e15)
                return ((long)d).ToString(CultureInfo.InvariantCulture);
            return d.ToString("R", CultureInfo.InvariantCulture);
        }

        private static void WriteString(StringBuilder sb, string s)
        {
            if (s == null) { sb.Append("null"); return; }
            sb.Append('"');
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    default:
                        if (c < 0x20 || c > 0x7E)
                            sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        else
                            sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }
    }

    internal static class Json
    {
        public sealed class ParseException : Exception
        {
            public ParseException(string message) : base(message) { }
        }

        public static JsonValue Parse(string text)
        {
            int i = 0;
            var value = ParseValue(text, ref i);
            return value;
        }

        /// Never throws — returns null on malformed input. Used for files we
        /// merely prefer to read (settings, history lines), where a corrupt
        /// file should degrade to defaults instead of blocking launch.
        public static JsonValue TryParse(string text)
        {
            try { return Parse(text); }
            catch { return null; }
        }

        private static JsonValue ParseValue(string s, ref int i)
        {
            SkipWhitespace(s, ref i);
            if (i >= s.Length) throw new ParseException("unexpected end of input");
            char c = s[i];
            if (c == '{') return ParseObject(s, ref i);
            if (c == '[') return ParseArray(s, ref i);
            if (c == '"') return JsonValue.From(ParseString(s, ref i));
            if (c == 't') { Expect(s, ref i, "true"); return JsonValue.From(true); }
            if (c == 'f') { Expect(s, ref i, "false"); return JsonValue.From(false); }
            if (c == 'n') { Expect(s, ref i, "null"); return new JsonValue(); }
            return JsonValue.From(ParseNumber(s, ref i));
        }

        private static JsonValue ParseObject(string s, ref int i)
        {
            var obj = JsonValue.NewObject();
            i++;
            SkipWhitespace(s, ref i);
            if (i < s.Length && s[i] == '}') { i++; return obj; }
            while (true)
            {
                SkipWhitespace(s, ref i);
                if (i >= s.Length || s[i] != '"') throw new ParseException("expected key string");
                string key = ParseString(s, ref i);
                SkipWhitespace(s, ref i);
                if (i >= s.Length || s[i] != ':') throw new ParseException("expected colon");
                i++;
                obj.Members[key] = ParseValue(s, ref i);
                SkipWhitespace(s, ref i);
                if (i >= s.Length) throw new ParseException("unterminated object");
                if (s[i] == ',') { i++; continue; }
                if (s[i] == '}') { i++; return obj; }
                throw new ParseException("expected comma or closing brace");
            }
        }

        private static JsonValue ParseArray(string s, ref int i)
        {
            var arr = JsonValue.NewArray();
            i++;
            SkipWhitespace(s, ref i);
            if (i < s.Length && s[i] == ']') { i++; return arr; }
            while (true)
            {
                arr.Items.Add(ParseValue(s, ref i));
                SkipWhitespace(s, ref i);
                if (i >= s.Length) throw new ParseException("unterminated array");
                if (s[i] == ',') { i++; continue; }
                if (s[i] == ']') { i++; return arr; }
                throw new ParseException("expected comma or closing bracket");
            }
        }

        private static string ParseString(string s, ref int i)
        {
            i++;
            var sb = new StringBuilder();
            while (i < s.Length)
            {
                char c = s[i++];
                if (c == '"') return sb.ToString();
                if (c != '\\') { sb.Append(c); continue; }
                if (i >= s.Length) break;
                char esc = s[i++];
                switch (esc)
                {
                    case '"': sb.Append('"'); break;
                    case '\\': sb.Append('\\'); break;
                    case '/': sb.Append('/'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'n': sb.Append('\n'); break;
                    case 'r': sb.Append('\r'); break;
                    case 't': sb.Append('\t'); break;
                    case 'u':
                        if (i + 4 > s.Length) throw new ParseException("bad unicode escape");
                        sb.Append((char)int.Parse(s.Substring(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                        i += 4;
                        break;
                    default: throw new ParseException("bad escape character");
                }
            }
            throw new ParseException("unterminated string");
        }

        private static double ParseNumber(string s, ref int i)
        {
            int start = i;
            if (i < s.Length && (s[i] == '-' || s[i] == '+')) i++;
            while (i < s.Length && (char.IsDigit(s[i]) || s[i] == '.' || s[i] == 'e' || s[i] == 'E' || s[i] == '+' || s[i] == '-')) i++;
            string slice = s.Substring(start, i - start);
            double d;
            if (!double.TryParse(slice, NumberStyles.Float, CultureInfo.InvariantCulture, out d))
                throw new ParseException("bad number");
            return d;
        }

        private static void Expect(string s, ref int i, string literal)
        {
            if (i + literal.Length > s.Length || string.CompareOrdinal(s, i, literal, 0, literal.Length) != 0)
                throw new ParseException("expected literal");
            i += literal.Length;
        }

        private static void SkipWhitespace(string s, ref int i)
        {
            while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
        }
    }
}
