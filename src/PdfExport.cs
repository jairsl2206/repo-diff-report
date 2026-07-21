using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ReporteCambiosSvn
{
    internal static class Pdf
    {
        public static string FindEdge()
        {
            var candidatos = new List<string>();
            string pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            if (!string.IsNullOrEmpty(pf86)) candidatos.Add(System.IO.Path.Combine(pf86, "Microsoft\\Edge\\Application\\msedge.exe"));
            if (!string.IsNullOrEmpty(pf)) candidatos.Add(System.IO.Path.Combine(pf, "Microsoft\\Edge\\Application\\msedge.exe"));
            try
            {
                using (var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                    "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\msedge.exe"))
                {
                    if (k != null)
                    {
                        var v = k.GetValue(null) as string;
                        if (!string.IsNullOrEmpty(v)) candidatos.Add(v);
                    }
                }
            }
            catch { }
            foreach (var c in candidatos)
                if (File.Exists(c)) return c;
            return null;
        }

        public static void ExportHtmlToPdf(string htmlPath, string pdfPath)
        {
            string edge = FindEdge();
            if (edge == null)
                throw new InvalidOperationException(
                    "No se encontro Microsoft Edge (incluido en Windows 10/11). " +
                    "Abra el HTML en un navegador y use Ctrl+P -> Guardar como PDF.");
            string dir = System.IO.Path.GetDirectoryName(pdfPath);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
            if (File.Exists(pdfPath)) File.Delete(pdfPath);
            LimpiarPerfilesViejos();
            string uri = new Uri(System.IO.Path.GetFullPath(htmlPath)).AbsoluteUri;

            string ultimoErr = "";
            string[] modos = { "--headless", "--headless=old" };
            for (int intento = 0; intento < modos.Length; intento++)
            {
                string perfil = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                    "RepCambiosEdge_" + Guid.NewGuid().ToString("N"));
                bool timedOut = false;
                var psi = new ProcessStartInfo();
                psi.FileName = edge;
                psi.Arguments = modos[intento] + " --disable-gpu --disable-extensions --no-first-run " +
                                "--no-default-browser-check --user-data-dir=\"" + perfil + "\" " +
                                "--no-pdf-header-footer --print-to-pdf-no-header " +
                                "--print-to-pdf=\"" + pdfPath + "\" \"" + uri + "\"";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                using (var p = Process.Start(psi))
                {
                    var errTask = Task.Run(() => p.StandardError.ReadToEnd());
                    var outTask = Task.Run(() => p.StandardOutput.ReadToEnd());
                    if (!p.WaitForExit(300000))
                    {
                        try { p.Kill(); } catch { }
                        ultimoErr = "Tiempo de espera agotado (5 min).";
                        timedOut = true;
                    }
                    else
                    {
                        string errTxt = "";
                        try { errTxt = (errTask.Result ?? "").Trim(); } catch { }
                        ultimoErr = "Codigo de salida " + p.ExitCode +
                                    (errTxt.Length > 0 ? ". " + errTxt : ".");
                    }
                }
                int esperaMs = timedOut ? 5000 : (intento == 0 ? 60000 : 30000);
                bool ok = EsperarArchivoPdf(pdfPath, esperaMs);
                try { Directory.Delete(perfil, true); } catch { }
                if (ok)
                {
                    MarcarScrollContinuo(pdfPath);
                    return;
                }
            }
            if (ultimoErr.Length > 500) ultimoErr = ultimoErr.Substring(0, 500) + "...";
            throw new InvalidOperationException("Edge no pudo generar el PDF. Detalle: " + ultimoErr);
        }

        private static bool EsperarArchivoPdf(string pdfPath, int timeoutMs)
        {
            var sw = Stopwatch.StartNew();
            long ultimo = -1;
            while (sw.ElapsedMilliseconds < timeoutMs)
            {
                try
                {
                    if (File.Exists(pdfPath))
                    {
                        long len = new FileInfo(pdfPath).Length;
                        if (len > 0 && len == ultimo)
                        {
                            try
                            {
                                using (var fs = new FileStream(pdfPath, FileMode.Open, FileAccess.Read, FileShare.None)) { }
                                return true;
                            }
                            catch (IOException) { }
                        }
                        ultimo = len;
                    }
                }
                catch { }
                System.Threading.Thread.Sleep(500);
            }
            return File.Exists(pdfPath) && new FileInfo(pdfPath).Length > 0;
        }

        private static void MarcarScrollContinuo(string pdfPath)
        {
            try
            {
                var lat = Encoding.GetEncoding(28591);
                var bytes = File.ReadAllBytes(pdfPath);
                string t = lat.GetString(bytes);
                if (t.Contains("/PageLayout")) return;

                int sxPos = t.LastIndexOf("startxref", StringComparison.Ordinal);
                if (sxPos < 0) return;
                var mSx = Regex.Match(t.Substring(sxPos), "startxref\\s+(\\d+)");
                if (!mSx.Success) return;
                string prevXref = mSx.Groups[1].Value;

                string rootNum = null;
                foreach (Match m in Regex.Matches(t, "/Root\\s+(\\d+)\\s+0\\s+R")) rootNum = m.Groups[1].Value;
                if (rootNum == null) return;
                string size = null;
                foreach (Match m in Regex.Matches(t, "/Size\\s+(\\d+)")) size = m.Groups[1].Value;
                if (size == null) return;
                string info = null;
                foreach (Match m in Regex.Matches(t, "/Info\\s+\\d+\\s+0\\s+R")) info = m.Value;

                Match objM = null;
                foreach (Match m in Regex.Matches(t, "(^|[\\r\\n])" + rootNum + " 0 obj\\b")) objM = m;
                if (objM == null) return;
                int objPos = objM.Index + objM.Groups[1].Length;
                int dictPos = t.IndexOf("<<", objPos, StringComparison.Ordinal);
                int endPos = t.IndexOf("endobj", objPos, StringComparison.Ordinal);
                if (dictPos < 0 || endPos < 0 || dictPos > endPos) return;
                string cuerpo = t.Substring(dictPos + 2, endPos - dictPos - 2).TrimEnd();

                string prefijo = (bytes.Length > 0 && bytes[bytes.Length - 1] != (byte)'\n') ? "\n" : "";
                string nuevoObj = prefijo + rootNum + " 0 obj\n<< /PageLayout /OneColumn " + cuerpo + "\nendobj\n";
                long objOffset = bytes.Length + prefijo.Length;
                long xrefOffset = bytes.Length + nuevoObj.Length;

                var sbT = new StringBuilder();
                sbT.Append(nuevoObj);
                sbT.Append("xref\n");
                sbT.Append(rootNum + " 1\n");
                sbT.Append(objOffset.ToString("D10") + " 00000 n\r\n");
                sbT.Append("trailer\n<< /Size " + size + " /Root " + rootNum + " 0 R" +
                           (info != null ? " " + info : "") + " /Prev " + prevXref + " >>\n");
                sbT.Append("startxref\n" + xrefOffset + "\n%%EOF\n");

                using (var fs = new FileStream(pdfPath, FileMode.Append, FileAccess.Write))
                {
                    var tail = lat.GetBytes(sbT.ToString());
                    fs.Write(tail, 0, tail.Length);
                }
            }
            catch { }
        }

        private static void LimpiarPerfilesViejos()
        {
            try
            {
                foreach (var d in Directory.GetDirectories(System.IO.Path.GetTempPath(), "RepCambiosEdge_*"))
                {
                    try
                    {
                        if (Directory.GetCreationTimeUtc(d) < DateTime.UtcNow.AddHours(-6))
                            Directory.Delete(d, true);
                    }
                    catch { }
                }
            }
            catch { }
        }
    }
}
