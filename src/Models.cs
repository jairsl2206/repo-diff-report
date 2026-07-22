using System.Collections.Generic;

namespace ReporteCambiosSvn
{
    internal enum VcsKind { Svn, Git }

    internal class SvnResult
    {
        public int ExitCode;
        public byte[] Bytes;
        public string StdErr;
    }

    internal class PathItem { public string Action; public string Path; }

    internal class LogEntry
    {
        public string Rev = "", FullRev = "", Author = "", Date = "", Msg = "";
        public List<string> Versiones = new List<string>();
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
        public string Autor = "";
        public string Vcs = "auto";
        public string Orden = "asc";
        public string Branch = "";
        public bool ExcluirMvnRelease = false;
        public bool ExcluirMvnPrepare = false;
        public bool ExportarZip = false;
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
        public string SalidaZip = "";
        public string ZipError = null;
        public int Revisiones, Archivos, Bloques;
        public List<string> SinCambios = new List<string>();
    }
}
