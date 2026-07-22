using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace ReporteCambiosSvn
{
    internal static class Proc
    {
        public static SvnResult Run(string exe, IEnumerable<string> args)
        {
            return Run(exe, args, null);
        }

        public static SvnResult Run(string exe, IEnumerable<string> args, Dictionary<string, string> env)
        {
            var psi = new ProcessStartInfo();
            psi.FileName = exe;
            var sb = new StringBuilder();
            foreach (var a in args)
            {
                if (sb.Length > 0) sb.Append(' ');
                if (a.Length == 0 || a.IndexOfAny(new[] { ' ', '\t', '"' }) >= 0)
                    sb.Append('"').Append(a.Replace("\"", "\\\"")).Append('"');
                else
                    sb.Append(a);
            }
            psi.Arguments = sb.ToString();
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;
            if (env != null)
            {
                foreach (var kv in env)
                    psi.EnvironmentVariables[kv.Key] = kv.Value;
            }
            using (var p = Process.Start(psi))
            {
                var errTask = Task.Run(() => p.StandardError.ReadToEnd());
                var ms = new MemoryStream();
                p.StandardOutput.BaseStream.CopyTo(ms);
                p.WaitForExit();
                return new SvnResult { ExitCode = p.ExitCode, Bytes = ms.ToArray(), StdErr = errTask.Result };
            }
        }
    }

    internal static class Svn
    {
        public static SvnResult RunRaw(IEnumerable<string> args)
        {
            return Proc.Run("svn", args);
        }

        public static bool Disponible()
        {
            try { RunRaw(new[] { "--version", "--quiet" }); return true; }
            catch { return false; }
        }

        public static List<string> ListBranches(string url)
        {
            var res = new List<string>();
            if (!Disponible()) return res;
            string branchesUrl = url.TrimEnd('/') + "/branches";
            var r = RunRaw(new[] { "ls", "--non-interactive", branchesUrl });
            if (r.ExitCode != 0) return res;
            string texto = Texto.DecodeBytes(r.Bytes);
            foreach (var linea in Regex.Split(texto, "\r?\n"))
            {
                var t = linea.TrimEnd('/').Trim();
                if (t.Length > 0) res.Add(t);
            }
            res.Sort(StringComparer.OrdinalIgnoreCase);
            return res;
        }
    }

    internal static class Git
    {
        private static readonly Dictionary<string, string> _gitEnv = new Dictionary<string, string>
        {
            { "GIT_TERMINAL_PROMPT", "0" },
            { "GIT_CLONE_PROTECTION_ACTIVE", "false" },
            { "GIT_SSH_COMMAND", "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" }
        };

        public static SvnResult Run(IEnumerable<string> args)
        {
            return Proc.Run("git", args, _gitEnv);
        }

        public static bool Disponible()
        {
            try { Run(new[] { "--version" }); return true; }
            catch { return false; }
        }

        public static List<string> ListRemoteBranches(string remoteUrl)
        {
            var res = new List<string>();
            if (!Disponible()) return res;
            var r = Run(new[] { "ls-remote", "--heads", remoteUrl });
            if (r.ExitCode != 0) return res;
            string texto = Texto.DecodeBytes(r.Bytes);
            foreach (var linea in Regex.Split(texto, "\r?\n"))
            {
                var parts = linea.Trim().Split('\t');
                if (parts.Length >= 2)
                {
                    string refName = parts[1];
                    string prefix = "refs/heads/";
                    if (refName.StartsWith(prefix))
                        res.Add(refName.Substring(prefix.Length));
                }
            }
            res.Sort(StringComparer.OrdinalIgnoreCase);
            return res;
        }

        public static List<string> ListLocalBranches(string dir)
        {
            var res = new List<string>();
            if (!Disponible()) return res;
            var r = Run(new[] { "-C", dir, "branch", "--format=%(refname:short)" });
            if (r.ExitCode == 0)
            {
                string texto = Texto.DecodeBytes(r.Bytes);
                foreach (var linea in Regex.Split(texto, "\r?\n"))
                {
                    var t = linea.Trim();
                    if (t.Length > 0) res.Add(t);
                }
            }
            var rr = Run(new[] { "-C", dir, "branch", "-r", "--format=%(refname:short)" });
            if (rr.ExitCode == 0)
            {
                string texto = Texto.DecodeBytes(rr.Bytes);
                foreach (var linea in Regex.Split(texto, "\r?\n"))
                {
                    var t = linea.Trim();
                    if (t.Length == 0) continue;
                    string prefix = "origin/";
                    if (t.StartsWith(prefix))
                    {
                        string name = t.Substring(prefix.Length);
                        if (name.Length > 0 && !name.Equals("HEAD", StringComparison.OrdinalIgnoreCase)
                            && !res.Contains(name))
                            res.Add(name);
                    }
                }
            }
            res.Sort(StringComparer.OrdinalIgnoreCase);
            return res;
        }

        public static string GetCurrentBranch(string dir)
        {
            if (!Disponible()) return "";
            var r = Run(new[] { "-C", dir, "rev-parse", "--abbrev-ref", "HEAD" });
            if (r.ExitCode != 0) return "";
            return Texto.DecodeBytes(r.Bytes).Trim();
        }
    }

    internal static class Texto
    {
        public static string DecodeBytes(byte[] bytes)
        {
            if (bytes == null || bytes.Length == 0) return "";
            try
            {
                return new UTF8Encoding(false, true).GetString(bytes);
            }
            catch (DecoderFallbackException)
            {
                int c437 = 0, c1252 = 0;
                for (int i = 0; i < bytes.Length; i++)
                {
                    byte b = bytes[i];
                    if (b == 0x81 || b == 0x82 || b == 0x8A || b == 0x90 || b == 0x9A || (b >= 0xA0 && b <= 0xA5)) c437++;
                    else if (b == 0xE1 || b == 0xE9 || b == 0xED || b == 0xF3 || b == 0xFA || b == 0xF1 ||
                             b == 0xC1 || b == 0xC9 || b == 0xCD || b == 0xD3 || b == 0xDA || b == 0xD1) c1252++;
                }
                return Encoding.GetEncoding(c437 > c1252 ? 437 : 1252).GetString(bytes);
            }
        }

        public static string E(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return WebUtility.HtmlEncode(s);
        }

        public static List<string> SplitLista(string valores)
        {
            var res = new List<string>();
            if (valores == null) return res;
            foreach (var p in valores.Split(','))
            {
                var t = p.Trim();
                if (t.Length > 0 && !res.Any(x => string.Equals(x, t, StringComparison.OrdinalIgnoreCase)))
                    res.Add(t);
            }
            return res;
        }
    }
}
