using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;

namespace ReporteCambiosSvn
{
    internal static class Engine
    {
        public static ReportResult Generate(ReportOptions opt, Action<int, int, string> progress, Func<bool> cancelado)
        {
            if (progress == null) progress = delegate { };
            if (cancelado == null) cancelado = () => false;

            var mods = new List<string>(opt.Modulos);
            var exts = new List<string>(opt.Extensiones);

            string orden = (opt.Orden ?? "asc").Trim().ToLowerInvariant();
            if (orden != "asc" && orden != "desc")
                throw new ArgumentException("Valor de -Orden no valido: \"" + opt.Orden + "\". Use asc (antiguas primero) o desc (recientes primero).");

            string objetivo = (opt.ProjectPath ?? "").Trim();
            if (objetivo.Length == 0) throw new ArgumentException("Debe indicar la URL o ruta del proyecto (SVN o Git).");
            if (!Regex.IsMatch(objetivo, "^[A-Za-z][A-Za-z0-9+.\\-]*://") && Directory.Exists(objetivo))
                objetivo = System.IO.Path.GetFullPath(objetivo);

            VcsKind kind = DetectarVcs(objetivo, opt.Vcs);
            string url = "", root = "", dirGit = "";
            if (kind == VcsKind.Svn)
            {
                if (!Svn.Disponible())
                    throw new InvalidOperationException("No se encontro svn.exe en el PATH. Instale un cliente SVN de linea de comandos.");
                progress(0, 1, "Consultando informacion del repositorio (SVN)...");
                InfoXml(objetivo, out url, out root);
            }
            else
            {
                if (Regex.IsMatch(objetivo, "^[A-Za-z][A-Za-z0-9+.\\-]*://"))
                    throw new ArgumentException("Para repositorios Git indique la carpeta local del clon (no una URL).");
                if (!Git.Disponible())
                    throw new InvalidOperationException("No se encontro git.exe en el PATH. Instale Git para Windows.");
                progress(0, 1, "Consultando informacion del repositorio (Git)...");
                var rt = Git.Run(new[] { "-C", objetivo, "rev-parse", "--show-toplevel" });
                if (rt.ExitCode != 0)
                    throw new InvalidOperationException("La carpeta no es un repositorio Git valido:\r\n" + rt.StdErr);
                dirGit = Texto.DecodeBytes(rt.Bytes).Trim();
                var rr = Git.Run(new[] { "-C", objetivo, "config", "--get", "remote.origin.url" });
                string remoto = rr.ExitCode == 0 ? Texto.DecodeBytes(rr.Bytes).Trim() : "";
                url = remoto.Length > 0 ? remoto : dirGit.Replace('\\', '/');
            }

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
                patron = new Regex(".", RegexOptions.IgnoreCase);
            var patronOtraX = new Regex("/(" + modPat + ")\\.([A-Za-z0-9]+)$", RegexOptions.IgnoreCase);

            string vcsNombre = kind == VcsKind.Git ? "Git" : "SVN";
            string prefRev = kind == VcsKind.Git ? "" : "r";
            progress(0, 1, "Consultando log " + vcsNombre + "...");
            List<LogEntry> entradas;
            if (kind == VcsKind.Git)
            {
                entradas = GitLogEntries(dirGit, opt.Desde, opt.Hasta, patron);
            }
            else
            {
                string rango = RevExpr(opt.Desde) + ":" + RevExpr(opt.Hasta);
                entradas = LogEntries(url, rango, patron);
            }
            var matched = entradas.Where(e => e.Targets.Count > 0).ToList();
            if (opt.ExcluirMvnRelease) matched = matched.Where(e => !EsCommitMavenRelease(e.Msg)).ToList();
            if (opt.ExcluirMvnPrepare) matched = matched.Where(e => !EsCommitMavenPrepare(e.Msg)).ToList();
            if (orden == "desc") matched.Reverse();

            var parsedPorRev = new Dictionary<string, List<KeyValuePair<string, FileDiff>>>();
            var modCount = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            int totArchivos = 0, totHunks = 0, idx = 0, svnPomFallos = 0;

            foreach (var e in matched)
            {
                idx++;
                if (cancelado()) throw new OperationCanceledException("Operacion cancelada por el usuario.");
                progress(idx, matched.Count, "Descargando diff " + prefRev + e.Rev + "  (" + idx + "/" + matched.Count + ")");

                e.Versiones = VersionesDeMensaje(e.Msg);
                if (e.Versiones.Count == 0)
                {
                    string vPom = "";
                    if (kind == VcsKind.Git)
                        vPom = PomVersionGit(dirGit, e.FullRev.Length > 0 ? e.FullRev : e.Rev);
                    else if (svnPomFallos < 2)
                    {
                        vPom = PomVersionSvn(url, e.Rev);
                        if (vPom.Length == 0) svnPomFallos++;
                    }
                    if (vPom.Length > 0) e.Versiones.Add(vPom);
                }

                string texto = kind == VcsKind.Git
                    ? GitDiffCommit(dirGit, e.FullRev.Length > 0 ? e.FullRev : e.Rev, e.Targets)
                    : DiffRevision(root, e.Rev, e.Targets);
                string errRev = null;
                Dictionary<string, List<string>> secciones;
                if (texto.StartsWith("@@ERROR@@"))
                {
                    errRev = texto.Substring(9);
                    secciones = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
                }
                else
                {
                    secciones = kind == VcsKind.Git ? SplitSeccionesGit(texto) : SplitSecciones(texto);
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

            string html = BuildHtml(opt, kind, url, mods, exts, entradas, matched, parsedPorRev, modCount, patronOtraX);

            string htmlPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ReporteCambios_" + Guid.NewGuid().ToString("N") + ".html");
            File.WriteAllText(htmlPath, html, new UTF8Encoding(true));

            var res = new ReportResult
            {
                Salida = htmlPath,
                Revisiones = matched.Count,
                Archivos = totArchivos,
                Bloques = totHunks
            };
            res.SinCambios = mods.Where(m => !modCount.ContainsKey(m)).ToList();
            return res;
        }

        public static void ExportarPdf(string htmlPath, string pdfPath)
        {
            Pdf.ExportHtmlToPdf(htmlPath, pdfPath);
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

        private static bool EsFecha(string v)
        {
            return Regex.IsMatch((v ?? "").Trim(), "^\\d{4}-\\d{2}-\\d{2}([ T]\\d{2}:\\d{2}(:\\d{2})?)?$");
        }

        public static VcsKind DetectarVcs(string objetivo, string vcsOpt)
        {
            string v = (vcsOpt ?? "auto").Trim().ToLowerInvariant();
            if (v == "svn") return VcsKind.Svn;
            if (v == "git") return VcsKind.Git;
            if (Regex.IsMatch(objetivo, "^[A-Za-z][A-Za-z0-9+.\\-]*://")) return VcsKind.Svn;
            if (Directory.Exists(objetivo))
            {
                if (Directory.Exists(System.IO.Path.Combine(objetivo, ".svn"))) return VcsKind.Svn;
                if (Git.Disponible())
                {
                    var r = Git.Run(new[] { "-C", objetivo, "rev-parse", "--is-inside-work-tree" });
                    if (r.ExitCode == 0) return VcsKind.Git;
                }
            }
            return VcsKind.Svn;
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

        // ------------------------------------------------------------- GIT
        private static List<LogEntry> GitLogEntries(string dir, string desde, string hasta, Regex patron)
        {
            var args = new List<string> { "-c", "core.quotepath=off", "-C", dir, "log", "--reverse", "--no-color",
                "--date=iso-strict", "--name-status",
                "--pretty=format:%x1e%h%x1f%H%x1f%an%x1f%ad%x1f%B%x1f" };
            string d = (desde ?? "").Trim();
            string h = (hasta ?? "").Trim();
            string rangoRev = null;
            if (d.Length > 0 && !EsFecha(d))
            {
                string fin = (h.Length > 0 && !EsFecha(h)) ? h : "HEAD";
                rangoRev = d + ".." + fin;
            }
            else if (d.Length > 0)
            {
                args.Add("--since=" + d);
            }
            if (EsFecha(h)) args.Add("--until=" + h);
            else if (rangoRev == null && h.Length > 0 && !h.Equals("HEAD", StringComparison.OrdinalIgnoreCase)) rangoRev = h;
            if (rangoRev != null) args.Add(rangoRev);

            var r = Git.Run(args);
            if (r.ExitCode != 0)
                throw new InvalidOperationException("git log fallo:\r\n" + r.StdErr);
            string texto = Texto.DecodeBytes(r.Bytes);

            var lista = new List<LogEntry>();
            foreach (var rec in texto.Split('\x1e'))
            {
                if (rec.Trim().Length == 0) continue;
                var partes = rec.Split(new[] { '\x1f' }, 6);
                if (partes.Length < 6) continue;
                var e = new LogEntry();
                e.Rev = partes[0].Trim();
                e.FullRev = partes[1].Trim();
                e.Author = partes[2].Trim();
                string dt = partes[3].Trim();
                try
                {
                    e.Date = DateTime.Parse(dt, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind)
                                     .ToLocalTime().ToString("yyyy-MM-dd HH:mm");
                }
                catch { e.Date = dt; }
                e.Msg = partes[4].Trim();
                foreach (var ln in Regex.Split(partes[5], "\r?\n"))
                {
                    var t = ln.Trim();
                    if (t.Length == 0) continue;
                    var cols = t.Split('\t');
                    if (cols.Length < 2) continue;
                    string st = cols[0].Trim();
                    if (st.Length == 0) continue;
                    string acc = st.Substring(0, 1).ToUpperInvariant();
                    if ("MADRC".IndexOf(acc, StringComparison.Ordinal) < 0) continue;
                    string ruta = cols[cols.Length - 1].Trim();
                    var item = new PathItem { Action = acc, Path = "/" + ruta.Replace('\\', '/') };
                    if (patron.IsMatch(item.Path)) e.Targets.Add(item);
                    else e.Others.Add(item);
                }
                lista.Add(e);
            }
            return lista;
        }

        private static string GitDiffCommit(string dir, string fullRev, List<PathItem> targets)
        {
            var rutas = targets.Where(t => t.Action != "D").Select(t => t.Path.TrimStart('/')).ToList();
            if (rutas.Count == 0) return "";
            var args = new List<string> { "-c", "core.quotepath=off", "-C", dir, "diff", "--no-color", "--unified=3",
                fullRev + "^", fullRev, "--" };
            args.AddRange(rutas);
            var r = Git.Run(args);
            if (r.ExitCode != 0)
            {
                var args2 = new List<string> { "-c", "core.quotepath=off", "-C", dir, "show", "--no-color", "--unified=3",
                    "--format=", fullRev, "--" };
                args2.AddRange(rutas);
                r = Git.Run(args2);
                if (r.ExitCode != 0 && r.Bytes.Length == 0)
                    return "@@ERROR@@" + r.StdErr;
            }
            return Texto.DecodeBytes(r.Bytes);
        }

        private static readonly Regex ReGitDiffHdr = new Regex("^diff --git a/(.+) b/(.+)$");

        private static Dictionary<string, List<string>> SplitSeccionesGit(string diffTexto)
        {
            var secciones = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
            string actual = null;
            List<string> buf = null;
            foreach (var linea in Regex.Split(diffTexto, "\r?\n"))
            {
                var m = ReGitDiffHdr.Match(linea);
                if (m.Success)
                {
                    if (actual != null) secciones[actual] = buf;
                    actual = BaseName(m.Groups[2].Value.Trim());
                    buf = new List<string>();
                }
                else if (actual != null)
                {
                    if (linea.StartsWith("Binary files ") || linea.StartsWith("GIT binary patch"))
                        buf.Add("Cannot display: archivo binario.");
                    else
                        buf.Add(linea);
                }
            }
            if (actual != null) secciones[actual] = buf;
            return secciones;
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
                e.FullRev = e.Rev;
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

        // ------------------------------------------- RESUMEN HEURISTICO
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

        private static bool EsCommitMavenRelease(string msg)
        {
            return Regex.IsMatch(msg ?? "", "\\[maven-release-plugin\\]\\s*prepare\\s+release", RegexOptions.IgnoreCase);
        }

        private static bool EsCommitMavenPrepare(string msg)
        {
            return Regex.IsMatch(msg ?? "", "\\[maven-release-plugin\\]\\s*prepare\\s+for\\s+next\\s+development\\s+iteration", RegexOptions.IgnoreCase);
        }

        private static string ParsePomVersion(string xmlTexto)
        {
            try
            {
                xmlTexto = (xmlTexto ?? "").TrimStart('\uFEFF', ' ', '\r', '\n', '\t');
                var doc = new XmlDocument();
                doc.LoadXml(xmlTexto);
                var root = doc.DocumentElement;
                if (root == null || root.LocalName != "project") return "";
                string vParent = "";
                foreach (XmlNode n in root.ChildNodes)
                {
                    if (n.NodeType != XmlNodeType.Element) continue;
                    if (n.LocalName == "version")
                    {
                        var v = (n.InnerText ?? "").Trim();
                        if (v.Length > 0) return v;
                    }
                    if (n.LocalName == "parent")
                    {
                        foreach (XmlNode c in n.ChildNodes)
                            if (c.NodeType == XmlNodeType.Element && c.LocalName == "version")
                                vParent = (c.InnerText ?? "").Trim();
                    }
                }
                return vParent;
            }
            catch { return ""; }
        }

        private static string PomVersionGit(string dir, string fullRev)
        {
            var r = Git.Run(new[] { "-c", "core.quotepath=off", "-C", dir, "show", fullRev + ":pom.xml" });
            if (r.ExitCode != 0) return "";
            return ParsePomVersion(Texto.DecodeBytes(r.Bytes));
        }

        private static string PomVersionSvn(string url, string rev)
        {
            var r = Svn.RunRaw(new[] { "cat", "--non-interactive", "-r", rev, url + "/pom.xml@" + rev });
            if (r.ExitCode != 0) return "";
            return ParsePomVersion(Texto.DecodeBytes(r.Bytes));
        }

        // ------------------------------------------------------------- HTML / DISE;O TOTVS
        private static string GetLogoBase64()
        {
            try
            {
                string exeDir = AppDomain.CurrentDomain.BaseDirectory;
                string logoPath = System.IO.Path.Combine(exeDir, "imagen.png");
                if (File.Exists(logoPath))
                    return Convert.ToBase64String(File.ReadAllBytes(logoPath));
            }
            catch { }
            return LogoB64;
        }

        private const string LogoB64 = "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";
        private const string IconoB64 = "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";

        private const string Css = @"
@page{size:landscape;margin:0}
body{font-family:Verdana,'Segoe UI',Arial,sans-serif;margin:0;padding:0;background:#fff;color:#002233;font-size:11px}
.cover-page{position:relative;z-index:200;background:#002233;min-height:100vh;display:flex;align-items:center;justify-content:center;page-break-after:always}
.cover-inner{text-align:center;padding:35px 40px 50px 40px;max-width:820px}
.cover-badge{display:inline-block;background:#FF8900;color:#fff;font-weight:700;font-size:14px;letter-spacing:5px;padding:8px 28px;border-radius:4px;margin-bottom:32px;text-transform:uppercase}
.cover-logo{display:block;height:72px;width:auto;margin:0 auto 8px auto;vertical-align:middle}
.cover-title{font-size:29px;font-weight:700;color:#fff;margin:0 0 8px 0;line-height:1.2}
.cover-subtitle{font-size:13px;font-weight:400;color:#00DBFF;margin:0 0 32px 0}
table.cinfo{margin:0 auto;border-collapse:collapse;font-size:12px;text-align:left}
table.cinfo td{padding:5px 14px;border:none;color:#EBEBEB;line-height:1.5}
table.cinfo td:first-child{color:#00DBFF;font-weight:600;white-space:nowrap;text-align:right;width:175px}
.cover-note{margin-top:36px;font-size:11px;color:#7F7A7F;max-width:560px;margin-left:auto;margin-right:auto;line-height:1.5}
.wrap{max-width:1500px;margin:0 auto;padding:8px 18px}
h1{font-size:20px;margin:8px 0;color:#002233}
h2{font-size:15px;margin:0;color:#002233}
.meta{color:#5C5C5C;font-size:11px}
.card{background:#fff;border:1px solid #C8D6E5;border-radius:8px;margin:16px 0;overflow:hidden}
.card>.hd{padding:10px 14px;background:#F5F7FA;border-bottom:1px solid #C8D6E5;display:flex;flex-wrap:wrap;gap:10px;align-items:baseline}
.badge{display:inline-block;background:#002233;color:#fff;border-radius:12px;padding:1px 10px;font-size:11px;font-weight:600}
.badge.ver{background:#00A8C5}
.badge.aut{background:#5C5C5C}
.msg{white-space:pre-wrap;background:#FFF8E1;border:1px solid #FFB30066;border-radius:6px;margin:10px 14px;padding:8px 12px;font-size:12px}
.expl{background:#E5F9FF;border:1px solid #00DBFF66;border-radius:6px;margin:8px 14px;padding:6px 10px;font-size:11.5px}
table.toc{width:100%;border-collapse:collapse;background:#fff;font-size:11.5px}
table.toc th,table.toc td{border:1px solid #C8D6E5;padding:5px 8px;text-align:left;vertical-align:top}
table.toc th{background:#F5F7FA;color:#002233}
table.diff{width:100%;border-collapse:collapse;table-layout:fixed;font-family:Consolas,'Courier New',monospace;font-size:11px}
table.diff td{border:0;padding:1px 6px;vertical-align:top;word-wrap:break-word;overflow-wrap:anywhere;white-space:pre-wrap}
td.num{width:40px;min-width:40px;color:#8C959F;text-align:right;background:#F5F7FA;border-right:1px solid #C8D6E5;user-select:none}
td.del{background:#FFEBE9}
td.add{background:#E6FFEC}
td.empty{background:#f0f2f5}
td.ctx{background:#fff}
tr.hunkhdr td{background:#E5F9FF;color:#004D6B;padding:3px 8px;font-weight:600;border-top:1px solid #C8D6E5;border-bottom:1px solid #C8D6E5}
details.file{margin:10px 14px;border:1px solid #C8D6E5;border-radius:6px;overflow:hidden}
details.file>summary{cursor:pointer;background:#F5F7FA;padding:7px 12px;font-weight:600;font-size:12px}
.small{font-size:10px;color:#5C5C5C}
.filehalf{background:#FAFBFC;border-bottom:1px solid #C8D6E5;padding:3px 10px;font-size:10px;color:#5C5C5C;display:flex}
.filehalf div{flex:1}
.btns{position:sticky;top:0;z-index:9;background:#fff;padding:8px 0;border-bottom:1px solid #EBEBEB;margin-bottom:4px}
button{background:#002233;color:#fff;border:0;border-radius:6px;padding:6px 14px;font-size:12px;cursor:pointer;margin-right:8px}
button:hover{background:#00A8C5}
.nochange{background:#fff;border:1px dashed #C8D6E5;border-radius:8px;padding:10px 14px;font-size:12px}
a{color:#004D6B;text-decoration:none} a:hover{text-decoration:underline;color:#00A8C5}
@media print{ .btns{display:none} body{background:#fff} .card{page-break-before:always} details.file{page-break-inside:auto} details.file>summary{page-break-after:avoid} .filehalf{page-break-after:avoid} .expl{page-break-after:avoid} .msg{page-break-inside:avoid} table.diff tr{page-break-inside:avoid} table.toc tr{page-break-inside:avoid} }
";
        private const string Js =
            "function setAll(open){document.querySelectorAll(\"details.file\").forEach(function(d){d.open=open;});}" +
            "function invertirOrden(){" +
            "var t=document.getElementById(\"idxrev\");" +
            "if(t&&t.rows.length>2){var b=t.tBodies[0];var rs=Array.prototype.slice.call(b.rows,1);var mk=document.createComment(\"x\");b.appendChild(mk);rs.reverse().forEach(function(r){b.insertBefore(r,mk);});b.removeChild(mk);}" +
            "var cs=Array.prototype.slice.call(document.querySelectorAll(\"div.card\"));" +
            "if(cs.length>1){var p=cs[0].parentNode;var m2=document.createComment(\"y\");p.insertBefore(m2,cs[0]);cs.reverse().forEach(function(c){p.insertBefore(c,m2);});p.removeChild(m2);}" +
            "}" +
            "window.addEventListener(\"beforeprint\",function(){document.querySelectorAll(\"details\").forEach(function(d){d.setAttribute(\"data-wasopen\",d.open?\"1\":\"0\");d.open=true;});});" +
            "window.addEventListener(\"afterprint\",function(){document.querySelectorAll(\"details\").forEach(function(d){if(d.getAttribute(\"data-wasopen\")===\"0\"){d.open=false;}d.removeAttribute(\"data-wasopen\");});});" +
            "window.addEventListener(\"load\",function(){var p=document.getElementsByClassName(\"page-num\");if(p.length){p[0].textContent=\"1\";}});";

        private static string BuildHtml(ReportOptions opt, VcsKind kind, string url, List<string> mods, List<string> exts,
            List<LogEntry> entradas, List<LogEntry> matched,
            Dictionary<string, List<KeyValuePair<string, FileDiff>>> parsedPorRev,
            Dictionary<string, int> modCount, Regex patronOtraX)
        {
            var sb = new StringBuilder(4 * 1024 * 1024);
            string nl = "\n";
            string ahora = DateTime.Now.ToString("yyyy-MM-dd HH:mm");
            string vcsNombre = kind == VcsKind.Git ? "Git" : "SVN";
            string prefRev = kind == VcsKind.Git ? "" : "r";
            string colRev = kind == VcsKind.Git ? "Commit" : "Revisi&oacute;n";

            sb.Append("<!DOCTYPE html><html lang='es'><head><meta charset='utf-8'>" + nl);
            sb.Append("<title>Reporte de cambios por archivo - Napse ahora es TOTVS</title>" + nl);
            sb.Append("<style>" + Css + "</style><script>" + Js + "</script></head><body>" + nl);

            // Portada
            string extsTxt = exts.Count > 0 ? "(." + Texto.E(string.Join(" / .", exts)) + ")" : "(cualquier extensi&oacute;n)";
            string modsTxt = mods.Count > 0 ? Texto.E(string.Join(", ", mods)) : "(todos los archivos)";
            string autorTxt = (opt.Autor ?? "").Trim().Length > 0 ? Texto.E(opt.Autor.Trim()) : "&mdash;";
            sb.Append("<div class='cover-page'><div class='cover-inner'>" + nl);
            sb.Append("<img class='cover-logo' src='data:image/png;base64," + GetLogoBase64() + "' alt='imagen'>" + nl);
            sb.Append("<div class='cover-badge'>CONFIDENCIAL</div>" + nl);
            sb.Append("<h1 class='cover-title'>Reporte de Cambios por Archivo</h1>" + nl);
            sb.Append("<p class='cover-subtitle'>Control de cambios sobre repositorio " + vcsNombre + "</p>" + nl);
            sb.Append("<table class='cinfo'>" + nl);
            sb.Append("<tr><td>Repositorio</td><td>" + Texto.E(url) + "</td></tr>" + nl);
            sb.Append("<tr><td>Rango analizado</td><td>" + Texto.E(opt.Desde) + " &rarr; " + Texto.E(opt.Hasta) + "</td></tr>" + nl);
            sb.Append("<tr><td>Filtro de archivos</td><td>" + modsTxt + " &nbsp;" + extsTxt + "</td></tr>" + nl);
            var excl = new List<string>();
            if (opt.ExcluirMvnRelease) excl.Add("commits de mvn release ([maven-release-plugin] prepare release)");
            if (opt.ExcluirMvnPrepare) excl.Add("commits de mvn prepare (prepare for next development iteration)");
            if (excl.Count > 0)
                sb.Append("<tr><td>Exclusiones</td><td>" + Texto.E(string.Join("; ", excl)) + "</td></tr>" + nl);
            sb.Append("<tr><td>Fecha de generaci&oacute;n</td><td>" + ahora + "</td></tr>" + nl);
            sb.Append("<tr><td>Autor</td><td>" + autorTxt + "</td></tr>" + nl);
            sb.Append("<tr><td>Compa&ntilde;&iacute;a</td><td>Napse ahora es TOTVS</td></tr>" + nl);
            sb.Append("</table>" + nl);
            sb.Append("<p class='cover-note'>Este documento contiene informaci&oacute;n confidencial propiedad de Napse Global / TOTVS. " +
                      "Se proh&iacute;be su reproducci&oacute;n, distribuci&oacute;n o divulgaci&oacute;n total o parcial " +
                      "sin autorizaci&oacute;n expresa.</p>" + nl);
            sb.Append("</div></div>" + nl);

            // Contenido
            sb.Append("<div class='wrap'>" + nl);
            sb.Append("<div class='btns'><button onclick='setAll(true)'>Expandir todo</button><button onclick='setAll(false)'>Colapsar todo</button><button onclick='invertirOrden()'>Invertir orden</button></div>" + nl);

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
            sb.Append("<table class='toc' id='idxrev'><tr><th style='width:80px'>" + colRev + "</th><th style='width:110px'>Fecha</th><th style='width:90px'>Versi&oacute;n</th><th style='width:110px'>Autor</th><th>Archivos afectados (del filtro)</th><th>Descripci&oacute;n</th></tr>" + nl);
            foreach (var e in matched)
            {
                var vs = e.Versiones;
                string vsTxt = vs.Count > 0 ? Texto.E(string.Join(", ", vs)) : "&mdash;";
                string modsRev = string.Join(", ", e.Targets.Select(t => BaseName(t.Path))
                    .Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x => x, StringComparer.OrdinalIgnoreCase));
                string fecha10 = e.Date.Length >= 10 ? e.Date.Substring(0, 10) : e.Date;
                sb.Append("<tr><td><a href='#r" + e.Rev + "'>" + prefRev + e.Rev + "</a></td><td>" + fecha10 + "</td><td>" + vsTxt +
                          "</td><td>" + Texto.E(e.Author) + "</td><td>" + Texto.E(modsRev) + "</td><td>" +
                          Texto.E(DescCorta(e.Msg, 110)) + "</td></tr>" + nl);
            }
            sb.Append("</table>" + nl);

            foreach (var e in matched)
            {
                var vs = e.Versiones;
                sb.Append("<div class='card' id='r" + e.Rev + "'><div class='hd'>" + nl);
                sb.Append("<span class='badge'>" + prefRev + e.Rev + "</span>" + nl);
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
                        sb.Append("<table class='diff'><colgroup><col style='width:40px'><col><col style='width:40px'><col></colgroup>" + nl);
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
                              e.Others.Count + "</summary><div style='padding:8px 12px;font-size:11px'>" + nl);
                    foreach (var o in e.Others)
                        sb.Append("<div>[" + Texto.E(o.Action) + "] " + Texto.E(o.Path) + "</div>" + nl);
                    sb.Append("</div></details>" + nl);
                }
                sb.Append("</div>" + nl);
            }

            string cmdTxt = kind == VcsKind.Git
                ? "git log --name-status + git diff commit^..commit"
                : "svn log --xml + svn diff -c REV";
            sb.Append("<p class='small'>Documento generado con ReporteCambios.exe (" + cmdTxt + "). Dise&ntilde;o corporativo Napse ahora es TOTVS.</p>" + nl);
            sb.Append("<p class='small'>Autor: Jair Salda&ntilde;a &middot; Napse Global &mdash; <b>Napse ahora es TOTVS</b>.</p>" + nl);
            sb.Append("</div></body></html>");
            return sb.ToString();
        }
    }
}

