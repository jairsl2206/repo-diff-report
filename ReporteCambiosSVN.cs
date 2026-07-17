// ============================================================================
//  ReporteCambiosSVN - Herramienta portable para Windows
//  Genera un reporte HTML de cambios SVN por modulo, con diffs lado a lado
//  (antes/despues), resumen heuristico por archivo (regex, sin IA) y
//  metadatos (revision, fecha, version, autor, descripcion).
//
//  Dependencia en tiempo de ejecucion: SOLO svn.exe en el PATH.
//  Compilacion: build.bat (usa csc.exe incluido en .NET Framework de Windows).
//
//  Uso:
//    ReporteCambiosSVN.exe                     -> interfaz grafica
//    ReporteCambiosSVN.exe -ProjectPath <url|carpeta> -Desde <fecha|rev>
//        [-Hasta <fecha|rev|HEAD>] -Archivos "A,B,C" [-Extensiones "BAS,DAT"]
//        [-Salida archivo.html] [-SinResumen] [-AbrirAlTerminar]
//        [-Pdf] [-SalidaPdf archivo.pdf]
//    (-Modulos se acepta como alias de -Archivos por compatibilidad)
//
//  La exportacion a PDF usa Microsoft Edge (incluido en Windows 10/11) en
//  modo headless; si no esta disponible, el HTML se genera igual y se avisa.
// ============================================================================
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Xml;

[assembly: AssemblyTitle("ReporteCambiosSVN")]
[assembly: AssemblyProduct("ReporteCambiosSVN")]
[assembly: AssemblyDescription("Reporte HTML de cambios SVN por modulo (diffs lado a lado). Solo requiere svn.exe")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace ReporteCambiosSvn
{
    // ------------------------------------------------------------------ SVN
    internal class SvnResult
    {
        public int ExitCode;
        public byte[] Bytes;
        public string StdErr;
    }

    internal static class Svn
    {
        public static SvnResult RunRaw(IEnumerable<string> args)
        {
            var psi = new ProcessStartInfo();
            psi.FileName = "svn";
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
            using (var p = Process.Start(psi))
            {
                var errTask = Task.Run(() => p.StandardError.ReadToEnd());
                var ms = new MemoryStream();
                p.StandardOutput.BaseStream.CopyTo(ms);
                p.WaitForExit();
                return new SvnResult { ExitCode = p.ExitCode, Bytes = ms.ToArray(), StdErr = errTask.Result };
            }
        }

        public static bool Disponible()
        {
            try { RunRaw(new[] { "--version", "--quiet" }); return true; }
            catch { return false; }
        }
    }

    // ----------------------------------------------------------------- TEXTO
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

    // ---------------------------------------------------------------- MODELO
    internal class PathItem { public string Action; public string Path; }

    internal class LogEntry
    {
        public string Rev = "", Author = "", Date = "", Msg = "";
        public List<PathItem> Targets = new List<PathItem>();
        public List<PathItem> Others = new List<PathItem>();
    }

    internal class HunkRow { public string Tipo, On, Ot, Nn, Nt; }

    internal class Hunk { public string Header; public List<HunkRow> Rows = new List<HunkRow>(); }

    internal class FileDiff
    {
        public string Action = "", Path = "", Err = null, Resumen = "";
        public bool Deleted, Missing, Binario, SoloProp;
        public List<Hunk> Hunks;
    }

    internal class ReportOptions
    {
        public string ProjectPath = "", Desde = "", Hasta = "HEAD", Salida = "";
        public List<string> Modulos = new List<string>();
        public List<string> Extensiones = new List<string>();
        public bool IncluirResumen = true;
        public bool AbrirAlTerminar = false;
        public bool ExportarPdf = false;
        public string SalidaPdf = "";
    }

    internal class ReportResult
    {
        public string Salida = "";
        public string SalidaPdf = "";
        public string PdfError = null;
        public int Revisiones, Archivos, Bloques;
        public List<string> SinCambios = new List<string>();
    }

    // ------------------------------------------------------------------ PDF
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
                // Perfil temporal UNICO por intento: evita bloqueos de instancias previas.
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
                // Edge puede delegar la impresion a un proceso hijo y salir de inmediato
                // (codigo 0): esperar a que el PDF aparezca y termine de escribirse.
                int esperaMs = timedOut ? 5000 : (intento == 0 ? 60000 : 30000);
                bool ok = EsperarArchivoPdf(pdfPath, esperaMs);
                try { Directory.Delete(perfil, true); } catch { }
                if (ok) return;
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

    // ---------------------------------------------------------------- MOTOR
    internal static class Engine
    {
        public static ReportResult Generate(ReportOptions opt, Action<int, int, string> progress, Func<bool> cancelado)
        {
            if (progress == null) progress = delegate { };
            if (cancelado == null) cancelado = () => false;

            if (!Svn.Disponible())
                throw new InvalidOperationException("No se encontro svn.exe en el PATH. Instale un cliente SVN de linea de comandos.");

            var mods = new List<string>(opt.Modulos);
            var exts = new List<string>(opt.Extensiones);

            string rango = RevExpr(opt.Desde) + ":" + RevExpr(opt.Hasta);

            string objetivo = (opt.ProjectPath ?? "").Trim();
            if (objetivo.Length == 0) throw new ArgumentException("Debe indicar la URL o ruta del proyecto SVN.");
            if (!Regex.IsMatch(objetivo, "^[A-Za-z][A-Za-z0-9+.\\-]*://") && Directory.Exists(objetivo))
                objetivo = System.IO.Path.GetFullPath(objetivo);

            progress(0, 1, "Consultando informacion del repositorio...");
            string url, root;
            InfoXml(objetivo, out url, out root);

            string modPat = string.Join("|", mods.Select(Regex.Escape));
            string extPat = string.Join("|", exts.Select(Regex.Escape));
            Regex patron;
            if (mods.Count > 0 && exts.Count > 0)
                patron = new Regex("/(" + modPat + ")\\.(" + extPat + ")$", RegexOptions.IgnoreCase);
            else if (mods.Count > 0)
                patron = new Regex("/(" + modPat + ")(\\.[A-Za-z0-9]+)?$", RegexOptions.IgnoreCase);
            else if (exts.Count > 0)
                patron = new Regex("\\.(" + extPat + ")$", RegexOptions.IgnoreCase);
            else
                patron = new Regex(".", RegexOptions.IgnoreCase); // todos los archivos
            var patronOtraX = new Regex("/(" + modPat + ")\\.([A-Za-z0-9]+)$", RegexOptions.IgnoreCase);

            progress(0, 1, "Consultando log SVN...");
            var entradas = LogEntries(url, rango, patron);
            var matched = entradas.Where(e => e.Targets.Count > 0).ToList();

            var parsedPorRev = new Dictionary<string, List<KeyValuePair<string, FileDiff>>>();
            var modCount = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            int totArchivos = 0, totHunks = 0, idx = 0;

            foreach (var e in matched)
            {
                idx++;
                if (cancelado()) throw new OperationCanceledException("Operacion cancelada por el usuario.");
                progress(idx, matched.Count, "Descargando diff r" + e.Rev + "  (" + idx + "/" + matched.Count + ")");

                string texto = DiffRevision(root, e.Rev, e.Targets);
                string errRev = null;
                Dictionary<string, List<string>> secciones;
                if (texto.StartsWith("@@ERROR@@"))
                {
                    errRev = texto.Substring(9);
                    secciones = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
                }
                else
                {
                    secciones = SplitSecciones(texto);
                }

                var archivos = new List<KeyValuePair<string, FileDiff>>();
                foreach (var t in e.Targets.OrderBy(x => BaseName(x.Path), StringComparer.OrdinalIgnoreCase))
                {
                    string baseNm = BaseName(t.Path);
                    string modNombre = baseNm.Split('.')[0].ToUpperInvariant();
                    int cnt;
                    modCount.TryGetValue(modNombre, out cnt);
                    modCount[modNombre] = cnt + 1;
                    totArchivos++;

                    var fd = new FileDiff { Action = t.Action, Path = t.Path };
                    if (t.Action == "D")
                    {
                        fd.Deleted = true;
                    }
                    else
                    {
                        List<string> sec;
                        if (!secciones.TryGetValue(baseNm, out sec))
                        {
                            fd.Missing = true;
                            fd.Err = errRev;
                        }
                        else
                        {
                            bool binario, soloProp;
                            fd.Hunks = ParseHunks(sec, out binario, out soloProp);
                            fd.Binario = binario;
                            fd.SoloProp = soloProp;
                            totHunks += fd.Hunks.Count;
                            if (opt.IncluirResumen && fd.Hunks.Count > 0)
                                fd.Resumen = ResumenArchivo(fd.Hunks);
                        }
                    }
                    archivos.Add(new KeyValuePair<string, FileDiff>(baseNm, fd));
                }
                parsedPorRev[e.Rev] = archivos;
            }

            progress(matched.Count, Math.Max(1, matched.Count), "Generando documento HTML...");

            string html = BuildHtml(opt, url, mods, exts, entradas, matched, parsedPorRev, modCount, patronOtraX);

            string salida = (opt.Salida ?? "").Trim();
            if (salida.Length == 0)
            {
                var segs = url.Split('/').Where(s => s.Length > 0).ToList();
                string proy = "proyecto";
                if (segs.Count >= 2) proy = segs[segs.Count - 2] + "_" + segs[segs.Count - 1];
                else if (segs.Count == 1) proy = segs[0];
                string nombre = Regex.Replace("REPORTE_CAMBIOS_" + proy + "_" + opt.Desde + "_a_" + opt.Hasta + ".html", "[^\\w\\-.]", "_");
                salida = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Desktop), nombre);
            }
            string dir = System.IO.Path.GetDirectoryName(salida);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(salida, html, new UTF8Encoding(true));

            var res = new ReportResult
            {
                Salida = salida,
                Revisiones = matched.Count,
                Archivos = totArchivos,
                Bloques = totHunks
            };
            res.SinCambios = mods.Where(m => !modCount.ContainsKey(m)).ToList();

            if (opt.ExportarPdf)
            {
                progress(matched.Count, Math.Max(1, matched.Count), "Exportando a PDF (Microsoft Edge integrado)...");
                string pdfPath = (opt.SalidaPdf ?? "").Trim();
                if (pdfPath.Length == 0) pdfPath = System.IO.Path.ChangeExtension(salida, ".pdf");
                try
                {
                    Pdf.ExportHtmlToPdf(salida, pdfPath);
                    res.SalidaPdf = pdfPath;
                }
                catch (Exception ex)
                {
                    res.PdfError = ex.Message;
                }
            }
            return res;
        }

        public static string RevExpr(string valor)
        {
            string v = (valor ?? "").Trim();
            if (v.Length == 0) throw new ArgumentException("Valor de fecha/revision vacio.");
            if (Regex.IsMatch(v, "^\\d+$")) return v;
            if (Regex.IsMatch(v, "^(HEAD|BASE|COMMITTED|PREV)$", RegexOptions.IgnoreCase)) return v.ToUpperInvariant();
            if (Regex.IsMatch(v, "^\\{.+\\}$")) return v;
            if (Regex.IsMatch(v, "^\\d{4}-\\d{2}-\\d{2}([ T]\\d{2}:\\d{2}(:\\d{2})?)?$")) return "{" + v + "}";
            throw new ArgumentException("Valor de fecha/revision no valido: \"" + v + "\". Use YYYY-MM-DD, un numero de revision o HEAD.");
        }

        private static string BaseName(string path)
        {
            var partes = path.Split('/', '\\');
            return partes[partes.Length - 1];
        }

        private static void InfoXml(string target, out string url, out string root)
        {
            var r = Svn.RunRaw(new[] { "info", "--xml", "--non-interactive", target });
            if (r.ExitCode != 0)
                throw new InvalidOperationException("svn info fallo para '" + target + "':\r\n" + r.StdErr);
            var xml = new XmlDocument();
            using (var ms = new MemoryStream(r.Bytes)) xml.Load(ms);
            var nUrl = xml.SelectSingleNode("/info/entry/url");
            var nRoot = xml.SelectSingleNode("/info/entry/repository/root");
            if (nUrl == null || nRoot == null)
                throw new InvalidOperationException("Respuesta inesperada de svn info.");
            url = nUrl.InnerText;
            root = nRoot.InnerText;
        }

        private static List<LogEntry> LogEntries(string url, string rango, Regex patron)
        {
            var r = Svn.RunRaw(new[] { "log", "-v", "--xml", "--non-interactive", "-r", rango, url });
            if (r.ExitCode != 0)
                throw new InvalidOperationException("svn log fallo:\r\n" + r.StdErr);
            var xml = new XmlDocument();
            using (var ms = new MemoryStream(r.Bytes)) xml.Load(ms);

            var lista = new List<LogEntry>();
            var nodos = xml.SelectNodes("/log/logentry");
            if (nodos == null) return lista;
            foreach (XmlNode le in nodos)
            {
                var e = new LogEntry();
                var attr = le.Attributes != null ? le.Attributes["revision"] : null;
                e.Rev = attr != null ? attr.Value : "";
                var nAut = le.SelectSingleNode("author");
                e.Author = nAut != null ? nAut.InnerText.Trim() : "";
                var nMsg = le.SelectSingleNode("msg");
                e.Msg = nMsg != null ? nMsg.InnerText.Trim() : "";
                var nDate = le.SelectSingleNode("date");
                if (nDate != null)
                {
                    string dt = nDate.InnerText;
                    try
                    {
                        e.Date = DateTime.Parse(dt, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind)
                                         .ToLocalTime().ToString("yyyy-MM-dd HH:mm");
                    }
                    catch
                    {
                        e.Date = dt.Length >= 16 ? dt.Substring(0, 16).Replace("T", " ") : dt;
                    }
                }
                var paths = le.SelectNodes("paths/path");
                if (paths != null)
                {
                    foreach (XmlNode p in paths)
                    {
                        var aAttr = p.Attributes != null ? p.Attributes["action"] : null;
                        var kAttr = p.Attributes != null ? p.Attributes["kind"] : null;
                        bool esDir = kAttr != null && kAttr.Value == "dir";
                        var item = new PathItem { Action = aAttr != null ? aAttr.Value : "", Path = p.InnerText };
                        if (!esDir && patron.IsMatch(item.Path)) e.Targets.Add(item);
                        else e.Others.Add(item);
                    }
                }
                lista.Add(e);
            }
            return lista;
        }

        private static string DiffRevision(string root, string rev, List<PathItem> targets)
        {
            var urls = targets.Where(t => t.Action != "D").Select(t => root + t.Path + "@" + rev).ToList();
            if (urls.Count == 0) return "";
            var args = new List<string> { "diff", "--non-interactive", "-c", rev };
            args.AddRange(urls);
            var r = Svn.RunRaw(args);
            if (r.ExitCode != 0 && r.Bytes.Length == 0)
                return "@@ERROR@@" + r.StdErr;
            return Texto.DecodeBytes(r.Bytes);
        }

        private static Dictionary<string, List<string>> SplitSecciones(string diffTexto)
        {
            var secciones = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
            string actual = null;
            List<string> buf = null;
            foreach (var linea in Regex.Split(diffTexto, "\r?\n"))
            {
                if (linea.StartsWith("Index: "))
                {
                    if (actual != null) secciones[actual] = buf;
                    actual = BaseName(linea.Substring(7).Trim());
                    buf = new List<string>();
                }
                else if (actual != null)
                {
                    buf.Add(linea);
                }
            }
            if (actual != null) secciones[actual] = buf;
            return secciones;
        }

        private static readonly Regex ReHunkHdr = new Regex("^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@");

        private static List<Hunk> ParseHunks(List<string> lineas, out bool binario, out bool soloProp)
        {
            var hunks = new List<Hunk>();
            binario = false;
            int i = 0;
            while (i < lineas.Count)
            {
                string ln = lineas[i];
                if (ln.StartsWith("Cannot display:")) { binario = true; break; }
                if (ln.StartsWith("Property changes on:")) break;
                var m = ReHunkHdr.Match(ln);
                if (m.Success)
                {
                    int oldNo = int.Parse(m.Groups[1].Value);
                    int newNo = int.Parse(m.Groups[3].Value);
                    var rows = new List<HunkRow>();
                    var dq = new List<Tuple<int, string>>();
                    var aq = new List<Tuple<int, string>>();
                    Action flush = () =>
                    {
                        int n = Math.Max(dq.Count, aq.Count);
                        for (int k = 0; k < n; k++)
                        {
                            Tuple<int, string> L = k < dq.Count ? dq[k] : null;
                            Tuple<int, string> R = k < aq.Count ? aq[k] : null;
                            if (L != null && R != null)
                                rows.Add(new HunkRow { Tipo = "rep", On = L.Item1.ToString(), Ot = L.Item2, Nn = R.Item1.ToString(), Nt = R.Item2 });
                            else if (L != null)
                                rows.Add(new HunkRow { Tipo = "del", On = L.Item1.ToString(), Ot = L.Item2, Nn = "", Nt = "" });
                            else
                                rows.Add(new HunkRow { Tipo = "add", On = "", Ot = "", Nn = R.Item1.ToString(), Nt = R.Item2 });
                        }
                        dq.Clear(); aq.Clear();
                    };
                    string hdrTxt = ln;
                    i++;
                    while (i < lineas.Count)
                    {
                        string l2 = lineas[i];
                        if (l2.StartsWith("@@") || l2.StartsWith("Index: ") || l2.StartsWith("Property changes on:") || l2.StartsWith("Cannot display:"))
                            break;
                        if (l2.StartsWith("\\")) { i++; continue; }
                        if (l2.StartsWith("-"))
                        {
                            dq.Add(Tuple.Create(oldNo, l2.Substring(1))); oldNo++;
                        }
                        else if (l2.StartsWith("+"))
                        {
                            aq.Add(Tuple.Create(newNo, l2.Substring(1))); newNo++;
                        }
                        else
                        {
                            flush();
                            string txt = l2.StartsWith(" ") ? l2.Substring(1) : l2;
                            rows.Add(new HunkRow { Tipo = "ctx", On = oldNo.ToString(), Ot = txt, Nn = newNo.ToString(), Nt = txt });
                            oldNo++; newNo++;
                        }
                        i++;
                    }
                    flush();
                    hunks.Add(new Hunk { Header = hdrTxt, Rows = rows });
                }
                else
                {
                    i++;
                }
            }
            soloProp = hunks.Count == 0 && !binario;
            return hunks;
        }

        // ------------------------------------------- RESUMEN HEURISTICO (sin IA)
        private static string ResumenArchivo(List<Hunk> hunks)
        {
            int adds = 0, dels = 0;
            var sbA = new StringBuilder();
            var sbR = new StringBuilder();
            var addedLines = new List<string>();
            foreach (var h in hunks)
            {
                foreach (var r in h.Rows)
                {
                    if (r.Tipo == "rep" || r.Tipo == "del") { dels++; sbR.AppendLine(r.Ot); }
                    if (r.Tipo == "rep" || r.Tipo == "add") { adds++; sbA.AppendLine(r.Nt); addedLines.Add(r.Nt); }
                }
            }
            string A = sbA.ToString(), R = sbR.ToString(), AR = A + "\n" + R;
            var partes = new List<string>();
            partes.Add(adds + " linea(s) agregadas, " + dels + " eliminadas en " + hunks.Count + " bloque(s)");

            var fnA = MatchSet(A, "\\bDEF\\s+(FN[\\w.$]+)");
            var fnR = MatchSet(R, "\\bDEF\\s+(FN[\\w.$]+)");
            var nuevas = fnA.Where(x => !fnR.Contains(x)).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
            var borradas = fnR.Where(x => !fnA.Contains(x)).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
            if (nuevas.Count > 0) partes.Add("nuevas funciones: " + Top(nuevas, 4));
            if (borradas.Count > 0) partes.Add("funciones eliminadas: " + Top(borradas, 4));

            var callA = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (Match m in Regex.Matches(A, "\\bCALL\\s+([A-Z0-9.$]{4,})", RegexOptions.IgnoreCase))
                callA[m.Groups[1].Value] = m.Groups[1].Value;
            var callR = MatchSet(R, "\\bCALL\\s+([A-Z0-9.$]{4,})");
            var callsNuevas = callA.Keys.Where(k => !callR.Contains(k)).Select(k => callA[k])
                                   .OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
            if (callsNuevas.Count > 0) partes.Add("nuevas llamadas: " + Top(callsNuevas, 4));

            if (Regex.IsMatch(AR, "%\\s*include", RegexOptions.IgnoreCase)) partes.Add("cambios en %INCLUDE");

            var temas = new List<string>();
            if (Regex.IsMatch(A, "(PRINT|TICKET|VOUCHER|IMPRE)", RegexOptions.IgnoreCase)) temas.Add("impresion ticket/voucher");
            if (Regex.IsMatch(A, "(ENMASC|MASK|X{4,}|ASTERIS)", RegexOptions.IgnoreCase)) temas.Add("enmascaramiento de datos");
            if (Regex.IsMatch(A, "(TLOG|STRING\\s*\\d)", RegexOptions.IgnoreCase)) temas.Add("registro TLOG/strings");
            if (Regex.IsMatch(A, "(WS\\.|HTTP|CICS|SOCKET)", RegexOptions.IgnoreCase)) temas.Add("web service/comunicaciones");
            if (Regex.IsMatch(A, "(TRAINING|ENTRENA)", RegexOptions.IgnoreCase)) temas.Add("modo entrenamiento");
            if (Regex.IsMatch(A, "(CASH\\s*ADV|WALLET)", RegexOptions.IgnoreCase)) temas.Add("cash advance/wallet");
            if (Regex.IsMatch(A, "TOKA", RegexOptions.IgnoreCase)) temas.Add("TOKA Pay");
            if (temas.Count > 0) partes.Add("temas: " + string.Join(", ", temas));

            var vers = new List<string>();
            foreach (Match m in Regex.Matches(A, "\\b(\\d+\\.\\d{2}\\.\\d{2})\\b"))
                if (!vers.Contains(m.Groups[1].Value)) vers.Add(m.Groups[1].Value);
            if (vers.Count > 0) partes.Add("version(es) referenciada(s): " + string.Join(", ", vers.Take(3)));

            if (adds > 0)
            {
                bool soloComentarios = true;
                foreach (var t in addedLines)
                {
                    var tt = (t ?? "").Trim();
                    if (tt.Length > 0 && !tt.StartsWith("!")) { soloComentarios = false; break; }
                }
                if (soloComentarios) partes.Add("solo comentarios/documentacion");
            }
            return string.Join("; ", partes) + ".";
        }

        private static HashSet<string> MatchSet(string texto, string patron)
        {
            var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (Match m in Regex.Matches(texto, patron, RegexOptions.IgnoreCase))
                set.Add(m.Groups[1].Value);
            return set;
        }

        private static string Top(List<string> items, int n)
        {
            string txt = string.Join(", ", items.Take(n));
            if (items.Count > n) txt += "...";
            return txt;
        }

        public static List<string> VersionesDeMensaje(string msg)
        {
            var res = new List<string>();
            foreach (Match m in Regex.Matches(msg ?? "", "versi[o\u00f3]n\\s+v?\\.?\\s*(\\d+(?:\\.\\d+){1,3})", RegexOptions.IgnoreCase))
                if (!res.Contains(m.Groups[1].Value)) res.Add(m.Groups[1].Value);
            return res;
        }

        public static string DescCorta(string msg, int max)
        {
            foreach (var l in Regex.Split(msg ?? "", "\r?\n"))
            {
                var t = l.Trim();
                if (t.Length > 0)
                    return t.Length > max ? t.Substring(0, max) + "..." : t;
            }
            return "";
        }

        // ------------------------------------------------------------- HTML
        private const string Css = @"
body{font-family:'Segoe UI',Arial,sans-serif;margin:0;background:#f0f2f5;color:#1f2328}
.wrap{max-width:1500px;margin:0 auto;padding:18px}
h1{font-size:22px;margin:8px 0}
h2{font-size:17px;margin:0}
.meta{color:#57606a;font-size:12px}
.card{background:#fff;border:1px solid #d0d7de;border-radius:8px;margin:16px 0;overflow:hidden}
.card>.hd{padding:10px 14px;background:#f6f8fa;border-bottom:1px solid #d0d7de;display:flex;flex-wrap:wrap;gap:10px;align-items:baseline}
.badge{display:inline-block;background:#0969da;color:#fff;border-radius:12px;padding:1px 10px;font-size:12px;font-weight:600}
.badge.ver{background:#8250df}
.badge.aut{background:#57606a}
.msg{white-space:pre-wrap;background:#fffbe6;border:1px solid #d4a72c66;border-radius:6px;margin:10px 14px;padding:8px 12px;font-size:13px}
.expl{background:#ddf4ff;border:1px solid #54aeff66;border-radius:6px;margin:8px 14px;padding:6px 10px;font-size:12.5px}
table.toc{width:100%;border-collapse:collapse;background:#fff;font-size:12.5px}
table.toc th,table.toc td{border:1px solid #d0d7de;padding:5px 8px;text-align:left;vertical-align:top}
table.toc th{background:#f6f8fa}
table.diff{width:100%;border-collapse:collapse;table-layout:fixed;font-family:Consolas,'Courier New',monospace;font-size:11.5px}
table.diff td{border:0;padding:1px 6px;vertical-align:top;word-wrap:break-word;overflow-wrap:anywhere;white-space:pre-wrap}
td.num{width:44px;min-width:44px;color:#8c959f;text-align:right;background:#f6f8fa;border-right:1px solid #d0d7de;user-select:none}
td.del{background:#ffebe9}
td.add{background:#e6ffec}
td.empty{background:#f0f2f5}
td.ctx{background:#fff}
tr.hunkhdr td{background:#ddf4ff;color:#0550ae;padding:3px 8px;font-weight:600;border-top:1px solid #d0d7de;border-bottom:1px solid #d0d7de}
details.file{margin:10px 14px;border:1px solid #d0d7de;border-radius:6px;overflow:hidden}
details.file>summary{cursor:pointer;background:#f6f8fa;padding:7px 12px;font-weight:600;font-size:13px}
.small{font-size:11px;color:#57606a}
.filehalf{background:#fafbfc;border-bottom:1px solid #d0d7de;padding:3px 10px;font-size:11px;color:#57606a;display:flex}
.filehalf div{flex:1}
.btns{position:sticky;top:0;z-index:9;background:#f0f2f5;padding:8px 0}
button{background:#0969da;color:#fff;border:0;border-radius:6px;padding:6px 12px;font-size:12.5px;cursor:pointer;margin-right:8px}
.nochange{background:#fff;border:1px dashed #d0d7de;border-radius:8px;padding:10px 14px;font-size:13px}
a{color:#0969da;text-decoration:none} a:hover{text-decoration:underline}
@page{size:landscape;margin:10mm}
@media print{ .btns{display:none} details.file{page-break-inside:avoid} body{background:#fff} }
";
        private const string Js = "function setAll(open){document.querySelectorAll(\"details.file\").forEach(function(d){d.open=open;});}";

        private static string BuildHtml(ReportOptions opt, string url, List<string> mods, List<string> exts,
            List<LogEntry> entradas, List<LogEntry> matched,
            Dictionary<string, List<KeyValuePair<string, FileDiff>>> parsedPorRev,
            Dictionary<string, int> modCount, Regex patronOtraX)
        {
            var sb = new StringBuilder(4 * 1024 * 1024);
            string nl = "\n";
            string ahora = DateTime.Now.ToString("yyyy-MM-dd HH:mm");

            sb.Append("<!DOCTYPE html><html lang='es'><head><meta charset='utf-8'>" + nl);
            sb.Append("<title>Reporte de cambios por archivo - SVN</title>" + nl);
            sb.Append("<style>" + Css + "</style><script>" + Js + "</script></head><body><div class='wrap'>" + nl);
            sb.Append("<h1>Reporte de cambios por archivo &mdash; " + Texto.E(url) + "</h1>" + nl);
            sb.Append("<div class='meta'>Rango: <b>" + Texto.E(opt.Desde) + " &rarr; " + Texto.E(opt.Hasta) +
                      "</b> &nbsp;|&nbsp; Generado: " + ahora +
                      " &nbsp;|&nbsp; Herramienta: ReporteCambiosSVN.exe (solo requiere svn.exe)</div>" + nl);
            string extsTxt = exts.Count > 0 ? "(." + Texto.E(string.Join(" / .", exts)) + ")" : "(cualquier extensi&oacute;n)";
            string modsTxt = mods.Count > 0 ? Texto.E(string.Join(", ", mods)) : "(todos los archivos)";
            sb.Append("<div class='meta'>Filtro de archivos: " + modsTxt +
                      " &nbsp;" + extsTxt + "</div>" + nl);
            sb.Append("<div class='btns'><button onclick='setAll(true)'>Expandir todo</button><button onclick='setAll(false)'>Colapsar todo</button></div>" + nl);

            sb.Append("<h2 style='margin-top:14px'>Resumen general</h2><p class='meta'>" + matched.Count +
                      " revisiones afectan los archivos listados. Total de cambios por archivo:</p>" + nl);
            sb.Append("<table class='toc'><tr><th>Archivo</th><th># Revisiones que lo modifican</th></tr>" + nl);
            foreach (var kv in modCount.OrderByDescending(k => k.Value))
                sb.Append("<tr><td>" + Texto.E(kv.Key) + "</td><td>" + kv.Value + "</td></tr>" + nl);
            sb.Append("</table>" + nl);

            var sinCambios = mods.Where(m => !modCount.ContainsKey(m)).ToList();
            if (sinCambios.Count > 0)
            {
                string extsNota = exts.Count > 0 ? " (." + Texto.E(string.Join("/.", exts)) + ")" : "";
                sb.Append("<p class='nochange'><b>Archivos sin cambios" + extsNota +
                          " en el periodo:</b> " + Texto.E(string.Join(", ", sinCambios)));
                if (exts.Count > 0)
                {
                    var notas = new List<string>();
                    foreach (var e in entradas)
                    {
                        foreach (var o in e.Others)
                        {
                            var m2 = patronOtraX.Match(o.Path);
                            if (!m2.Success) continue;
                            string modU = m2.Groups[1].Value.ToUpperInvariant();
                            string extV = m2.Groups[2].Value;
                            bool esExtFiltrada = exts.Any(x => string.Equals(x, extV, StringComparison.OrdinalIgnoreCase));
                            bool esSinCambio = sinCambios.Any(x => string.Equals(x, modU, StringComparison.OrdinalIgnoreCase));
                            if (esSinCambio && !esExtFiltrada)
                            {
                                string nota = modU + "." + extV + " (r" + e.Rev + ")";
                                if (!notas.Contains(nota)) notas.Add(nota);
                            }
                        }
                    }
                    if (notas.Count > 0)
                        sb.Append("<br><span class='small'>Nota: hubo cambios con otra extensi&oacute;n (fuera del filtro): " +
                                  Texto.E(string.Join(", ", notas.OrderBy(x => x, StringComparer.OrdinalIgnoreCase))) + "</span>");
                }
                sb.Append("</p>" + nl);
            }

            sb.Append("<h2>&Iacute;ndice de revisiones</h2>" + nl);
            sb.Append("<table class='toc'><tr><th style='width:70px'>Revisi&oacute;n</th><th style='width:110px'>Fecha</th><th style='width:90px'>Versi&oacute;n</th><th style='width:110px'>Autor</th><th>Archivos afectados (del filtro)</th><th>Descripci&oacute;n</th></tr>" + nl);
            foreach (var e in matched)
            {
                var vs = VersionesDeMensaje(e.Msg);
                string vsTxt = vs.Count > 0 ? Texto.E(string.Join(", ", vs)) : "&mdash;";
                string modsRev = string.Join(", ", e.Targets.Select(t => BaseName(t.Path))
                    .Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x => x, StringComparer.OrdinalIgnoreCase));
                string fecha10 = e.Date.Length >= 10 ? e.Date.Substring(0, 10) : e.Date;
                sb.Append("<tr><td><a href='#r" + e.Rev + "'>r" + e.Rev + "</a></td><td>" + fecha10 + "</td><td>" + vsTxt +
                          "</td><td>" + Texto.E(e.Author) + "</td><td>" + Texto.E(modsRev) + "</td><td>" +
                          Texto.E(DescCorta(e.Msg, 110)) + "</td></tr>" + nl);
            }
            sb.Append("</table>" + nl);

            foreach (var e in matched)
            {
                var vs = VersionesDeMensaje(e.Msg);
                sb.Append("<div class='card' id='r" + e.Rev + "'><div class='hd'>" + nl);
                sb.Append("<span class='badge'>r" + e.Rev + "</span>" + nl);
                foreach (var v in vs) sb.Append("<span class='badge ver'>v" + Texto.E(v) + "</span>" + nl);
                sb.Append("<span class='badge aut'>" + Texto.E(e.Author) + "</span>" + nl);
                sb.Append("<h2>" + Texto.E(e.Date) + "</h2></div>" + nl);
                string msgHtml = e.Msg.Length > 0 ? Texto.E(e.Msg) : "(sin mensaje)";
                sb.Append("<div class='msg'><b>Descripci&oacute;n del commit:</b>" + nl + msgHtml + "</div>" + nl);

                foreach (var par in parsedPorRev[e.Rev])
                {
                    string baseNm = par.Key;
                    var ia = par.Value;
                    string accion = ia.Action;
                    if (ia.Action == "M") accion = "Modificado";
                    else if (ia.Action == "A") accion = "Agregado";
                    else if (ia.Action == "D") accion = "Eliminado";
                    else if (ia.Action == "R") accion = "Reemplazado";

                    sb.Append("<details class='file' open><summary>" + Texto.E(baseNm) + " <span class='small'>(" +
                              accion + " &mdash; " + Texto.E(ia.Path) + ")</span></summary>" + nl);
                    if (ia.Deleted)
                    {
                        sb.Append("<div class='expl'>Archivo eliminado en esta revisi&oacute;n.</div>" + nl);
                    }
                    else if (ia.Missing)
                    {
                        string msgErr = "No se obtuvo diff (posible cambio solo de propiedades).";
                        if (!string.IsNullOrEmpty(ia.Err) && ia.Err.Trim().Length > 0) msgErr = ia.Err;
                        sb.Append("<div class='expl'>&#9888; " + Texto.E(msgErr) + "</div>" + nl);
                    }
                    else if (ia.Binario)
                    {
                        sb.Append("<div class='expl'>Archivo binario: no es posible mostrar diff textual.</div>" + nl);
                    }
                    else if (ia.SoloProp)
                    {
                        sb.Append("<div class='expl'>Solo cambios de propiedades SVN (sin cambios de contenido).</div>" + nl);
                    }
                    else
                    {
                        if (opt.IncluirResumen && ia.Resumen.Length > 0)
                            sb.Append("<div class='expl'><b>Resumen:</b> " + Texto.E(ia.Resumen) + "</div>" + nl);
                        sb.Append("<div class='filehalf'><div>&#9664; ANTES (izquierda)</div><div>DESPU&Eacute;S (derecha) &#9654;</div></div>" + nl);
                        sb.Append("<table class='diff'><colgroup><col style='width:44px'><col><col style='width:44px'><col></colgroup>" + nl);
                        foreach (var h in ia.Hunks)
                        {
                            sb.Append("<tr class='hunkhdr'><td colspan='4'>" + Texto.E(h.Header) + "</td></tr>" + nl);
                            foreach (var r in h.Rows)
                            {
                                string ot = Texto.E(r.Ot), nt = Texto.E(r.Nt);
                                if (r.Tipo == "ctx")
                                    sb.Append("<tr><td class='num'>" + r.On + "</td><td class='ctx'>" + ot + "</td><td class='num'>" + r.Nn + "</td><td class='ctx'>" + nt + "</td></tr>" + nl);
                                else if (r.Tipo == "rep")
                                    sb.Append("<tr><td class='num'>" + r.On + "</td><td class='del'>" + ot + "</td><td class='num'>" + r.Nn + "</td><td class='add'>" + nt + "</td></tr>" + nl);
                                else if (r.Tipo == "del")
                                    sb.Append("<tr><td class='num'>" + r.On + "</td><td class='del'>" + ot + "</td><td class='num'></td><td class='empty'></td></tr>" + nl);
                                else
                                    sb.Append("<tr><td class='num'></td><td class='empty'></td><td class='num'>" + r.Nn + "</td><td class='add'>" + nt + "</td></tr>" + nl);
                            }
                        }
                        sb.Append("</table>" + nl);
                    }
                    sb.Append("</details>" + nl);
                }

                if (e.Others.Count > 0)
                {
                    sb.Append("<details class='file'><summary class='small'>Otras rutas modificadas en esta revisi&oacute;n (fuera del filtro): " +
                              e.Others.Count + "</summary><div style='padding:8px 12px;font-size:11.5px'>" + nl);
                    foreach (var o in e.Others)
                        sb.Append("<div>[" + Texto.E(o.Action) + "] " + Texto.E(o.Path) + "</div>" + nl);
                    sb.Append("</div></details>" + nl);
                }
                sb.Append("</div>" + nl);
            }

            sb.Append("<p class='small'>Documento generado con ReporteCambiosSVN.exe (svn log --xml + svn diff -c REV). El resumen por archivo es heur&iacute;stico (regex), sin IA. Para una &quot;captura&quot; imprimible: Ctrl+P &rarr; Guardar como PDF.</p>" + nl);
            sb.Append("</div></body></html>");
            return sb.ToString();
        }
    }

    // ------------------------------------------------------------------ GUI
    internal class MainForm : Form
    {
        private const string TtProj = "URL del repositorio SVN (https://...) o carpeta local de un working copy.\r\nEjemplo: https://servidor/svn/repo/trunk";
        private const string TtDesde = "Inicio del rango a analizar.\r\nAcepta fecha (YYYY-MM-DD) o numero de revision.\r\nEjemplos: 2025-08-01  |  31490";
        private const string TtHasta = "Fin del rango a analizar.\r\nAcepta fecha (YYYY-MM-DD), numero de revision o HEAD (ultima revision).";
        private const string TtArchivos = "Nombres de los archivos a identificar, separados por coma (sin ruta).\r\nEjemplo: SUBTSPAG,USRTTLOG,USRTDUMP\r\nVacio = se incluyen TODOS los archivos modificados.\r\nSe combinan con Extensiones; si escribe el nombre con extension (ej. VENTAS.BAS), deje Extensiones vacio.";
        private const string TtExts = "Extensiones a considerar, separadas por coma. Ejemplo: BAS,DAT\r\nVacio = cualquier extension.";
        private const string TtResumen = "Agrega a cada archivo un resumen del cambio generado localmente con reglas de texto (expresiones regulares):\r\nlineas agregadas/eliminadas, funciones nuevas o eliminadas, llamadas nuevas y temas detectados.\r\nNo usa IA ni servicios externos: el resultado es determinista.";
        private const string TtSalida = "Ruta del archivo HTML a generar.\r\nVacio = se crea automaticamente en el Escritorio.";
        private const string TtAbrir = "Al terminar, abre el PDF (si se exporto) o el HTML.";
        private const string TtPdf = "Ademas del HTML, genera un PDF en hoja apaisada.\r\nUsa Microsoft Edge incluido en Windows 10/11 en modo oculto.\r\nSi Edge no esta disponible, el HTML se genera igual y se muestra un aviso.";
        private const string TtEstado = "Requisito: cliente svn.exe en el PATH.";

        private TextBox txtProj, txtDesde, txtHasta, txtMods, txtExts, txtSalida;
        private CheckBox chkResumen, chkAbrir, chkPdf;
        private ProgressBar pb;
        private Label lblEstado;
        private Button btnGo, btnCancel, btnCerrar, btnDir, btnSalida;
        private BackgroundWorker bw;
        private ToolTip tips;
        private const string PhArchivos = "Vacio = todos los archivos. Ej: SUBTSPAG,USRTTLOG,USRTDUMP";

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
        private const int EM_SETCUEBANNER = 0x1501;

        private static void SetPlaceholder(TextBox t, string texto)
        {
            SendMessage(t.Handle, EM_SETCUEBANNER, (IntPtr)1, texto);
        }

        private void SetPlaceholderMultilinea(TextBox t, string texto)
        {
            t.GotFocus += delegate
            {
                if (t.ForeColor == Color.Gray) { t.Text = ""; t.ForeColor = SystemColors.WindowText; }
            };
            t.LostFocus += delegate
            {
                if (t.Text.Trim().Length == 0) { t.ForeColor = Color.Gray; t.Text = texto; }
            };
            if (t.Text.Trim().Length == 0) { t.ForeColor = Color.Gray; t.Text = texto; }
        }

        private static string TextoReal(TextBox t)
        {
            return t.ForeColor == Color.Gray ? "" : t.Text;
        }

        private static void SetTextoReal(TextBox t, string valor, string placeholder)
        {
            if (!string.IsNullOrEmpty(valor)) { t.ForeColor = SystemColors.WindowText; t.Text = valor; }
            else { t.ForeColor = Color.Gray; t.Text = placeholder; }
        }

        private static string ConfigPath
        {
            get
            {
                return System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "ReporteCambiosSVN", "ultima_config.txt");
            }
        }

        private void GuardarConfig()
        {
            try
            {
                string dir = System.IO.Path.GetDirectoryName(ConfigPath);
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                var lineas = new List<string>
                {
                    "proyecto=" + txtProj.Text.Trim(),
                    "desde=" + txtDesde.Text.Trim(),
                    "hasta=" + txtHasta.Text.Trim(),
                    "archivos=" + TextoReal(txtMods).Trim(),
                    "extensiones=" + txtExts.Text.Trim(),
                    "salida=" + txtSalida.Text.Trim(),
                    "resumen=" + (chkResumen.Checked ? "1" : "0"),
                    "abrir=" + (chkAbrir.Checked ? "1" : "0"),
                    "pdf=" + (chkPdf.Checked ? "1" : "0")
                };
                File.WriteAllLines(ConfigPath, lineas, new UTF8Encoding(true));
            }
            catch { }
        }

        private void CargarConfig()
        {
            try
            {
                if (!File.Exists(ConfigPath)) return;
                var cfg = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (var ln in File.ReadAllLines(ConfigPath, Encoding.UTF8))
                {
                    int p = ln.IndexOf('=');
                    if (p > 0) cfg[ln.Substring(0, p)] = ln.Substring(p + 1);
                }
                string v;
                if (cfg.TryGetValue("proyecto", out v)) txtProj.Text = v;
                if (cfg.TryGetValue("desde", out v)) txtDesde.Text = v;
                if (cfg.TryGetValue("hasta", out v) && v.Trim().Length > 0) txtHasta.Text = v;
                if (cfg.TryGetValue("archivos", out v)) SetTextoReal(txtMods, v, PhArchivos);
                if (cfg.TryGetValue("extensiones", out v)) txtExts.Text = v;
                if (cfg.TryGetValue("salida", out v)) txtSalida.Text = v;
                if (cfg.TryGetValue("resumen", out v)) chkResumen.Checked = v != "0";
                if (cfg.TryGetValue("abrir", out v)) chkAbrir.Checked = v != "0";
                if (cfg.TryGetValue("pdf", out v)) chkPdf.Checked = v == "1";
            }
            catch { }
        }

        public MainForm()
        {
            Text = "Reporte de cambios SVN por modulo";
            ClientSize = new Size(704, 540);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9f);

            tips = new ToolTip();
            tips.AutoPopDelay = 30000;
            tips.InitialDelay = 350;
            tips.ReshowDelay = 100;

            int y = 15;
            var lProj = AddLbl("Proyecto SVN:", 15, y, 500);
            y += 20;
            txtProj = AddTxt(15, y, 580);
            btnDir = AddBtn("Carpeta...", 605, y - 1, 85, 25);
            btnDir.Click += BtnDir_Click;
            tips.SetToolTip(lProj, TtProj);
            tips.SetToolTip(txtProj, TtProj);
            tips.SetToolTip(btnDir, "Seleccionar la carpeta de un working copy local.");
            SetPlaceholder(txtProj, "https://servidor/svn/repo/trunk  o  C:\\ruta\\workingcopy");

            y += 38;
            var lDesde = AddLbl("Desde:", 15, y, 280);
            var lHasta = AddLbl("Hasta:", 320, y, 280);
            y += 20;
            txtDesde = AddTxt(15, y, 280);
            txtHasta = AddTxt(320, y, 280);
            txtHasta.Text = "HEAD";
            tips.SetToolTip(lDesde, TtDesde);
            tips.SetToolTip(txtDesde, TtDesde);
            tips.SetToolTip(lHasta, TtHasta);
            tips.SetToolTip(txtHasta, TtHasta);
            SetPlaceholder(txtDesde, "Fecha YYYY-MM-DD o revision. Ej: 2025-08-01 | 31490");
            SetPlaceholder(txtHasta, "Fecha YYYY-MM-DD, revision o HEAD");

            y += 38;
            var lArch = AddLbl("Archivos a identificar:", 15, y, 500);
            y += 20;
            txtMods = AddTxt(15, y, 675);
            txtMods.Multiline = true;
            txtMods.ScrollBars = ScrollBars.Vertical;
            txtMods.Height = 62;
            tips.SetToolTip(lArch, TtArchivos);
            tips.SetToolTip(txtMods, TtArchivos);
            SetPlaceholderMultilinea(txtMods, PhArchivos);

            y += 75;
            var lExts = AddLbl("Extensiones:", 15, y, 280);
            y += 20;
            txtExts = AddTxt(15, y, 280);
            tips.SetToolTip(lExts, TtExts);
            tips.SetToolTip(txtExts, TtExts);
            SetPlaceholder(txtExts, "Vacio = todas. Ej: BAS,DAT");
            chkResumen = new CheckBox();
            chkResumen.Text = "Incluir resumen por archivo";
            chkResumen.Location = new Point(320, y - 2);
            chkResumen.Size = new Size(370, 23);
            chkResumen.Checked = true;
            Controls.Add(chkResumen);
            tips.SetToolTip(chkResumen, TtResumen);

            y += 38;
            var lSalida = AddLbl("Archivo de salida:", 15, y, 500);
            y += 20;
            txtSalida = AddTxt(15, y, 580);
            btnSalida = AddBtn("Guardar...", 605, y - 1, 85, 25);
            btnSalida.Click += BtnSalida_Click;
            tips.SetToolTip(lSalida, TtSalida);
            tips.SetToolTip(txtSalida, TtSalida);
            tips.SetToolTip(btnSalida, "Elegir donde guardar el HTML.");
            SetPlaceholder(txtSalida, "Vacio = autogenerado en el Escritorio");

            y += 34;
            chkAbrir = new CheckBox();
            chkAbrir.Text = "Abrir el reporte al terminar";
            chkAbrir.Location = new Point(15, y);
            chkAbrir.Size = new Size(300, 23);
            chkAbrir.Checked = true;
            Controls.Add(chkAbrir);
            tips.SetToolTip(chkAbrir, TtAbrir);
            chkPdf = new CheckBox();
            chkPdf.Text = "Exportar tambien a PDF";
            chkPdf.Location = new Point(320, y);
            chkPdf.Size = new Size(370, 23);
            Controls.Add(chkPdf);
            tips.SetToolTip(chkPdf, TtPdf);

            y += 32;
            pb = new ProgressBar();
            pb.Location = new Point(15, y);
            pb.Size = new Size(675, 20);
            pb.Minimum = 0;
            pb.Maximum = 100;
            Controls.Add(pb);
            y += 24;
            lblEstado = AddLbl("Listo.", 15, y, 675);
            tips.SetToolTip(lblEstado, TtEstado);

            y += 28;
            btnGo = AddBtn("Generar reporte", 15, y, 140, 30);
            btnGo.Click += BtnGo_Click;
            btnCancel = AddBtn("Cancelar", 165, y, 100, 30);
            btnCancel.Enabled = false;
            btnCancel.Click += BtnCancel_Click;
            btnCerrar = AddBtn("Cerrar", 590, y, 100, 30);
            btnCerrar.Click += delegate { Close(); };

            bw = new BackgroundWorker();
            bw.WorkerReportsProgress = true;
            bw.WorkerSupportsCancellation = true;
            bw.DoWork += Bw_DoWork;
            bw.ProgressChanged += Bw_ProgressChanged;
            bw.RunWorkerCompleted += Bw_RunWorkerCompleted;

            CargarConfig();
            FormClosing += delegate { GuardarConfig(); };
        }

        private Label AddLbl(string txt, int x, int y, int w)
        {
            var l = new Label();
            l.Text = txt;
            l.Location = new Point(x, y);
            l.Size = new Size(w, 18);
            l.AutoSize = false;
            Controls.Add(l);
            return l;
        }

        private TextBox AddTxt(int x, int y, int w)
        {
            var t = new TextBox();
            t.Location = new Point(x, y);
            t.Size = new Size(w, 23);
            Controls.Add(t);
            return t;
        }

        private Button AddBtn(string txt, int x, int y, int w, int h)
        {
            var b = new Button();
            b.Text = txt;
            b.Location = new Point(x, y);
            b.Size = new Size(w, h);
            Controls.Add(b);
            return b;
        }

        private void BtnDir_Click(object sender, EventArgs e)
        {
            using (var dlg = new FolderBrowserDialog())
            {
                dlg.Description = "Seleccione la carpeta del working copy SVN";
                if (dlg.ShowDialog(this) == DialogResult.OK) txtProj.Text = dlg.SelectedPath;
            }
        }

        private void BtnSalida_Click(object sender, EventArgs e)
        {
            using (var dlg = new SaveFileDialog())
            {
                dlg.Filter = "Documento HTML (*.html)|*.html";
                dlg.FileName = "REPORTE_CAMBIOS.html";
                if (dlg.ShowDialog(this) == DialogResult.OK) txtSalida.Text = dlg.FileName;
            }
        }

        private void BtnCancel_Click(object sender, EventArgs e)
        {
            bw.CancelAsync();
            lblEstado.Text = "Cancelando...";
        }

        private void BtnGo_Click(object sender, EventArgs e)
        {
            try
            {
                if (!Svn.Disponible()) throw new InvalidOperationException("No se encontro svn.exe en el PATH.");
                if (txtProj.Text.Trim().Length == 0) throw new ArgumentException("Indique la URL o carpeta del proyecto SVN.");
                if (txtDesde.Text.Trim().Length == 0) throw new ArgumentException("Indique el valor \"Desde\" (fecha o revision).");

                var opt = new ReportOptions();
                opt.ProjectPath = txtProj.Text.Trim();
                opt.Desde = txtDesde.Text.Trim();
                opt.Hasta = txtHasta.Text.Trim().Length > 0 ? txtHasta.Text.Trim() : "HEAD";
                opt.Modulos = Texto.SplitLista(TextoReal(txtMods));
                opt.Extensiones = Texto.SplitLista(txtExts.Text);
                opt.Salida = txtSalida.Text.Trim();
                opt.IncluirResumen = chkResumen.Checked;
                opt.ExportarPdf = chkPdf.Checked;

                GuardarConfig();
                SetBusy(true);
                pb.Value = 0;
                bw.RunWorkerAsync(opt);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void SetBusy(bool busy)
        {
            btnGo.Enabled = !busy;
            btnCancel.Enabled = busy;
            btnCerrar.Enabled = !busy;
            txtProj.Enabled = !busy; txtDesde.Enabled = !busy; txtHasta.Enabled = !busy;
            txtMods.Enabled = !busy; txtExts.Enabled = !busy; txtSalida.Enabled = !busy;
            btnDir.Enabled = !busy; btnSalida.Enabled = !busy;
            chkResumen.Enabled = !busy; chkAbrir.Enabled = !busy; chkPdf.Enabled = !busy;
        }

        private void Bw_DoWork(object sender, DoWorkEventArgs e)
        {
            var opt = (ReportOptions)e.Argument;
            var worker = (BackgroundWorker)sender;
            var res = Engine.Generate(
                opt,
                (i, t, m) => worker.ReportProgress(t > 0 ? Math.Min(100, i * 100 / t) : 0, m),
                () => worker.CancellationPending);
            e.Result = res;
        }

        private void Bw_ProgressChanged(object sender, ProgressChangedEventArgs e)
        {
            pb.Value = Math.Max(0, Math.Min(100, e.ProgressPercentage));
            lblEstado.Text = (string)(e.UserState ?? "");
        }

        private void Bw_RunWorkerCompleted(object sender, RunWorkerCompletedEventArgs e)
        {
            SetBusy(false);
            if (e.Error is OperationCanceledException)
            {
                lblEstado.Text = "Operacion cancelada.";
                pb.Value = 0;
                return;
            }
            if (e.Error != null)
            {
                lblEstado.Text = "Error.";
                MessageBox.Show(this, e.Error.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            var res = (ReportResult)e.Result;
            pb.Value = 100;
            lblEstado.Text = "Listo: " + res.Salida;
            string detalle = "Reporte generado." + Environment.NewLine +
                             "Revisiones: " + res.Revisiones + Environment.NewLine +
                             "Archivos con diff: " + res.Archivos + Environment.NewLine +
                             "Bloques de cambio: " + res.Bloques + Environment.NewLine + Environment.NewLine +
                             res.Salida;
            if (res.SalidaPdf.Length > 0) detalle += Environment.NewLine + "PDF: " + res.SalidaPdf;
            MessageBox.Show(this, detalle, "Reporte SVN", MessageBoxButtons.OK, MessageBoxIcon.Information);
            if (res.PdfError != null)
                MessageBox.Show(this, "El HTML se genero correctamente, pero fallo la exportacion a PDF:" +
                                Environment.NewLine + res.PdfError, "PDF", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            if (chkAbrir.Checked)
            {
                string abrir = res.SalidaPdf.Length > 0 ? res.SalidaPdf : res.Salida;
                try { Process.Start(abrir); } catch { }
            }
        }
    }

    // -------------------------------------------------------------- PROGRAMA
    internal static class Program
    {
        [DllImport("kernel32.dll")]
        private static extern bool AttachConsole(int dwProcessId);
        private const int ATTACH_PARENT_PROCESS = -1;

        [STAThread]
        private static int Main(string[] args)
        {
            bool gui = args.Length == 0 || args.Any(a => a.Equals("-Gui", StringComparison.OrdinalIgnoreCase));
            if (gui)
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new MainForm());
                return 0;
            }

            AttachConsole(ATTACH_PARENT_PROCESS);
            Console.WriteLine();
            try
            {
                var opt = ParseArgs(args);
                var res = Engine.Generate(opt, (i, t, m) => Console.WriteLine("  " + m), () => false);
                Console.WriteLine("Reporte generado : " + res.Salida);
                Console.WriteLine("Revisiones       : " + res.Revisiones);
                Console.WriteLine("Archivos con diff: " + res.Archivos);
                Console.WriteLine("Bloques de cambio: " + res.Bloques);
                if (res.SalidaPdf.Length > 0)
                    Console.WriteLine("PDF generado     : " + res.SalidaPdf);
                if (res.PdfError != null)
                    Console.WriteLine("ADVERTENCIA PDF  : " + res.PdfError);
                if (res.SinCambios.Count > 0)
                    Console.WriteLine("Sin cambios      : " + string.Join(", ", res.SinCambios));
                if (opt.AbrirAlTerminar)
                {
                    try { Process.Start(res.SalidaPdf.Length > 0 ? res.SalidaPdf : res.Salida); } catch { }
                }
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("ERROR: " + ex.Message);
                Console.Error.WriteLine();
                Console.Error.WriteLine(Uso());
                return 1;
            }
        }

        private static string Uso()
        {
            return "Uso:\r\n" +
                   "  ReporteCambiosSVN.exe                          (interfaz grafica)\r\n" +
                   "  ReporteCambiosSVN.exe -ProjectPath <url|carpeta> -Desde <fecha|rev>\r\n" +
                   "      [-Hasta <fecha|rev|HEAD>] [-Archivos \"A,B,C\"] [-Extensiones \"BAS,DAT\"]\r\n" +
                   "      [-Salida archivo.html] [-SinResumen] [-AbrirAlTerminar]\r\n" +
                   "      [-Pdf] [-SalidaPdf archivo.pdf]\r\n" +
                   "Notas: -Modulos es alias de -Archivos. Sin -Archivos y/o sin -Extensiones\r\n" +
                   "       se incluyen TODOS los archivos / cualquier extension.\r\n" +
                   "Dependencia: solo svn.exe en el PATH. El PDF usa Edge integrado en Windows.";
        }

        private static ReportOptions ParseArgs(string[] args)
        {
            var opt = new ReportOptions();
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i].ToLowerInvariant();
                if (a == "-projectpath") opt.ProjectPath = Next(args, ref i, a);
                else if (a == "-desde") opt.Desde = Next(args, ref i, a);
                else if (a == "-hasta") opt.Hasta = Next(args, ref i, a);
                else if (a == "-archivos" || a == "-modulos") opt.Modulos = Texto.SplitLista(Next(args, ref i, a));
                else if (a == "-extensiones") opt.Extensiones = Texto.SplitLista(Next(args, ref i, a));
                else if (a == "-salida") opt.Salida = Next(args, ref i, a);
                else if (a == "-sinresumen") opt.IncluirResumen = false;
                else if (a == "-abriralterminar") opt.AbrirAlTerminar = true;
                else if (a == "-pdf") opt.ExportarPdf = true;
                else if (a == "-salidapdf") { opt.SalidaPdf = Next(args, ref i, a); opt.ExportarPdf = true; }
                else if (a == "-gui") { }
                else throw new ArgumentException("Parametro no reconocido: " + args[i]);
            }
            if (opt.ProjectPath.Trim().Length == 0) throw new ArgumentException("Falta -ProjectPath (URL o carpeta local del proyecto SVN).");
            if (opt.Desde.Trim().Length == 0) throw new ArgumentException("Falta -Desde (fecha YYYY-MM-DD o revision).");
            if (opt.Hasta.Trim().Length == 0) opt.Hasta = "HEAD";
            return opt;
        }

        private static string Next(string[] args, ref int i, string clave)
        {
            i++;
            if (i >= args.Length) throw new ArgumentException("Falta el valor para " + clave);
            return args[i];
        }
    }
}
