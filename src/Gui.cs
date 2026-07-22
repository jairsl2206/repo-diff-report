using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("ReporteCambios")]
[assembly: AssemblyProduct("ReporteCambios")]
[assembly: AssemblyDescription("Reporte HTML/PDF de cambios SVN/Git por archivo (diffs lado a lado). Autor: Jair Salda\u00f1a. Requiere svn.exe y/o git.exe")]
[assembly: AssemblyCompany("Napse Global \u00b7 TOTVS")]
[assembly: AssemblyCopyright("\u00a9 2026 Jair Salda\u00f1a \u00b7 Napse Global \u2014 Napse ahora es TOTVS")]
[assembly: AssemblyVersion("1.2.4.0")]
[assembly: AssemblyFileVersion("1.2.4.0")]

namespace ReporteCambiosSvn
{
    internal class MainForm : Form
    {
        private const string TtProj = "URL del repositorio remoto (SVN: https://..., Git: git@... o https://...git)\r\no carpeta local de un working copy SVN / repositorio Git clonado.\r\nSe detecta automaticamente el tipo de repositorio.\r\nGit remoto: requiere acceso SSH/HTTPS configurado en su equipo.\r\nSi selecciona una carpeta local, se extraera automaticamente la URL del repositorio remoto.\r\nEjemplo SVN: https://servidor/svn/repo/trunk\r\nEjemplo Git:  git@github.com:usuario/repo.git  |  C:\\repos\\mi-proyecto";
        private const string TtDesde = "Inicio del rango a analizar.\r\nSVN: fecha (YYYY-MM-DD) o numero de revision.\r\nGit: fecha o commit/tag (el commit inicial no se incluye: rango desde..hasta).\r\nEjemplos: 2025-08-01  |  31490  |  1f95ed4";
        private const string TtHasta = "Fin del rango a analizar.\r\nSVN: fecha, numero de revision o HEAD.\r\nGit: fecha, commit/tag o HEAD.";
        private const string TtArchivos = "Nombres de los archivos a identificar, separados por coma (sin ruta).\r\nEjemplo: SUBTSPAG,USRTTLOG,USRTDUMP\r\nVacio = se incluyen TODOS los archivos modificados.\r\nSe combinan con Extensiones; si escribe el nombre con extension (ej. VENTAS.BAS), deje Extensiones vacio.";
        private const string TtExts = "Extensiones a considerar, separadas por coma. Ejemplo: BAS,DAT\r\nVacio = cualquier extension.";
        private const string TtResumen = "Agrega a cada archivo un resumen del cambio generado localmente con reglas de texto (expresiones regulares):\r\nlineas agregadas/eliminadas, funciones nuevas o eliminadas, llamadas nuevas y temas detectados.\r\nNo usa IA ni servicios externos: el resultado es determinista.";
        private const string TtSalida = "Ruta del archivo PDF a generar (formato principal).\r\nVacio = se crea automaticamente en el Escritorio.";
        private const string TtAutor = "Nombre que aparecera como Autor en la portada del reporte.\r\nSe recuerda para la proxima ejecucion.";
        private const string TtOrden = "Orden de las revisiones en el reporte, por fecha.\r\nDentro del HTML tambien puedes cambiarlo con el boton 'Invertir orden'.";
        private const string TtExclRel = "Omite los commits generados por el maven-release-plugin al hacer el release:\r\nmensajes '[maven-release-plugin] prepare release ...'.";
        private const string TtExclPrep = "Omite los commits del maven-release-plugin que saltan a la siguiente version SNAPSHOT:\r\nmensajes '[maven-release-plugin] prepare for next development iteration'.";
        private const string TtEstado = "Requisito: svn.exe (repos SVN) y/o git.exe (repos Git) en el PATH.";

        private TextBox txtProj, txtDesde, txtHasta, txtMods, txtExts, txtSalida, txtAutor, txtLog;
        private ComboBox cboOrden, cboBranch;
        private CheckBox chkResumen, chkExclRel, chkExclPrep;
        private ProgressBar pb;
        private Label lblEstado;
        private Button btnGo, btnCancel, btnCerrar, btnDir, btnSalida, btnBranch;
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
                    "ReporteCambios", "ultima_config.txt");
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
                    "autor=" + txtAutor.Text.Trim(),
                    "orden=" + (cboOrden.SelectedIndex == 1 ? "desc" : "asc"),
                    "branch=" + (cboBranch.SelectedItem != null ? cboBranch.SelectedItem.ToString() : ""),
                    "exclrelease=" + (chkExclRel.Checked ? "1" : "0"),
                    "exclprepare=" + (chkExclPrep.Checked ? "1" : "0"),
                    "resumen=" + (chkResumen.Checked ? "1" : "0")
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
                if (cfg.TryGetValue("autor", out v)) txtAutor.Text = v;
                if (cfg.TryGetValue("orden", out v)) cboOrden.SelectedIndex = v == "desc" ? 1 : 0;
                if (cfg.TryGetValue("branch", out v) && v.Trim().Length > 0)
                {
                    if (cboBranch.Items.Count == 0) cboBranch.Items.Add(v);
                    cboBranch.SelectedItem = v;
                }
                if (cfg.TryGetValue("exclrelease", out v)) chkExclRel.Checked = v == "1";
                if (cfg.TryGetValue("exclprepare", out v)) chkExclPrep.Checked = v == "1";
                if (cfg.TryGetValue("resumen", out v)) chkResumen.Checked = v != "0";
            }
            catch { }
        }

        public MainForm()
        {
            Text = "Reporte de cambios por modulo";
            ClientSize = new Size(704, 710);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9f);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            tips = new ToolTip();
            tips.AutoPopDelay = 30000;
            tips.InitialDelay = 350;
            tips.ReshowDelay = 100;

            int y = 15;
            var lProj = AddLbl("URL de repositorio remoto:", 15, y, 500);
            y += 20;
            txtProj = AddTxt(15, y, 580);
            btnDir = AddBtn("Carpeta...", 605, y - 1, 85, 25);
            btnDir.Click += BtnDir_Click;
            tips.SetToolTip(lProj, TtProj);
            tips.SetToolTip(txtProj, TtProj);
            tips.SetToolTip(btnDir, "Seleccionar la carpeta de un working copy local (SVN o Git).");
            SetPlaceholder(txtProj, "https://servidor/svn/repo/trunk  |  git@github.com:user/repo.git  |  C:\\ruta\\repo");

            y += 30;
            var lBranch = AddLbl("Rama:", 15, y, 100);
            y += 20;
            cboBranch = new ComboBox();
            cboBranch.Location = new Point(15, y);
            cboBranch.Size = new Size(280, 23);
            cboBranch.DropDownStyle = ComboBoxStyle.DropDownList;
            cboBranch.Items.Add("trunk");
            cboBranch.SelectedIndex = 0;
            Controls.Add(cboBranch);
            btnBranch = AddBtn("Actualizar ramas", 305, y - 1, 120, 25);
            btnBranch.Click += BtnBranch_Click;
            tips.SetToolTip(lBranch, "Rama del repositorio a analizar. Use 'Actualizar ramas' para cargar la lista desde el repositorio.");
            tips.SetToolTip(cboBranch, "Rama del repositorio a analizar. En SVN, 'trunk' es la rama principal.");
            tips.SetToolTip(btnBranch, "Consultar al repositorio remoto la lista de ramas disponibles.");
            var lblBranchStatus = new Label();
            lblBranchStatus.Location = new Point(435, y + 2);
            lblBranchStatus.Size = new Size(250, 18);
            lblBranchStatus.AutoSize = false;
            lblBranchStatus.ForeColor = Color.Gray;
            Controls.Add(lblBranchStatus);
            lblBranchStatus.Name = "lblBranchStatus";
            txtProj.TextChanged += delegate
            {
                var s = Controls.Find("lblBranchStatus", true);
                if (s.Length > 0) s[0].Text = "Use 'Actualizar ramas' para cargar las ramas del repositorio.";
            };

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
            var lAutor = AddLbl("Autor del reporte:", 15, y, 280);
            var lOrden = AddLbl("Orden de revisiones:", 320, y, 280);
            y += 20;
            txtAutor = AddTxt(15, y, 280);
            tips.SetToolTip(lAutor, TtAutor);
            tips.SetToolTip(txtAutor, TtAutor);
            SetPlaceholder(txtAutor, "Nombre de quien genera el reporte");
            cboOrden = new ComboBox();
            cboOrden.Location = new Point(320, y);
            cboOrden.Size = new Size(280, 23);
            cboOrden.DropDownStyle = ComboBoxStyle.DropDownList;
            cboOrden.Items.Add("Mas antiguas primero (ascendente)");
            cboOrden.Items.Add("Mas recientes primero (descendente)");
            cboOrden.SelectedIndex = 0;
            Controls.Add(cboOrden);
            tips.SetToolTip(lOrden, TtOrden);
            tips.SetToolTip(cboOrden, TtOrden);

            y += 28;
            chkExclRel = new CheckBox();
            chkExclRel.Text = "Excluir commits de mvn release";
            chkExclRel.Location = new Point(15, y);
            chkExclRel.Size = new Size(300, 23);
            Controls.Add(chkExclRel);
            tips.SetToolTip(chkExclRel, TtExclRel);
            chkExclPrep = new CheckBox();
            chkExclPrep.Text = "Excluir commits de mvn prepare";
            chkExclPrep.Location = new Point(320, y);
            chkExclPrep.Size = new Size(370, 23);
            Controls.Add(chkExclPrep);
            tips.SetToolTip(chkExclPrep, TtExclPrep);

            y += 38;
            var lSalida = AddLbl("Archivo de salida:", 15, y, 500);
            y += 20;
            txtSalida = AddTxt(15, y, 580);
            btnSalida = AddBtn("Guardar...", 605, y - 1, 85, 25);
            btnSalida.Click += BtnSalida_Click;
            tips.SetToolTip(lSalida, TtSalida);
            tips.SetToolTip(txtSalida, TtSalida);
            tips.SetToolTip(btnSalida, "Elegir donde guardar el HTML.");
            SetPlaceholder(txtSalida, "Vacio = PDF autogenerado en el Escritorio");

            y += 40;
            pb = new ProgressBar();
            pb.Location = new Point(15, y);
            pb.Size = new Size(675, 20);
            pb.Minimum = 0;
            pb.Maximum = 100;
            Controls.Add(pb);
            y += 24;
            lblEstado = AddLbl("Listo.", 15, y, 675);
            tips.SetToolTip(lblEstado, TtEstado);

            y += 22;
            AddLbl("Log:", 15, y, 100);
            y += 16;
            txtLog = new TextBox();
            txtLog.Location = new Point(15, y);
            txtLog.Size = new Size(675, 55);
            txtLog.Multiline = true;
            txtLog.ScrollBars = ScrollBars.Vertical;
            txtLog.ReadOnly = true;
            txtLog.BackColor = SystemColors.Window;
            txtLog.Font = new Font("Consolas", 8f);
            txtLog.Text = "";
            Controls.Add(txtLog);
            tips.SetToolTip(txtLog, "Registro de traza. Muestra los comandos ejecutados y su resultado para diagnosticar fallos.");

            y += 60;
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

            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;

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
                dlg.Description = "Seleccione la carpeta del repositorio local (SVN o Git)";
                string actual = txtProj.Text.Trim();
                if (actual.Length > 0 && Directory.Exists(actual))
                    dlg.SelectedPath = actual;
                if (dlg.ShowDialog(this) == DialogResult.OK)
                {
                    txtProj.Text = dlg.SelectedPath;
                    CargarRamas();
                }
            }
        }

        private void BtnBranch_Click(object sender, EventArgs e)
        {
            CargarRamas();
        }

        private void CargarRamas()
        {
            string proyecto = txtProj.Text.Trim();
            LogMsg("Consultando ramas para: " + proyecto);
            if (proyecto.Length == 0)
            {
                var status = Controls.Find("lblBranchStatus", true);
                if (status.Length > 0) status[0].Text = "Primero indique la URL o carpeta del proyecto.";
                return;
            }
            var statusLbl = Controls.Find("lblBranchStatus", true);
            if (statusLbl.Length > 0) statusLbl[0].Text = "Consultando ramas...";
            cboBranch.Enabled = false;
            try
            {
                var ramas = Engine.ListarRamas(proyecto, "auto");
                LogMsg("Ramas encontradas: " + ramas.Count + " (" + string.Join(", ", ramas) + ")");
                string anterior = cboBranch.SelectedItem != null ? cboBranch.SelectedItem.ToString() : "";
                cboBranch.Items.Clear();
                if (ramas.Count == 0)
                {
                    cboBranch.Items.Add("trunk");
                    cboBranch.SelectedIndex = 0;
                    if (statusLbl.Length > 0) statusLbl[0].Text = "Sin ramas detectadas. Usando trunk.";
                }
                else
                {
                    foreach (var r in ramas) cboBranch.Items.Add(r);
                    int idx = -1;
                    if (anterior.Length > 0)
                    {
                        for (int i = 0; i < cboBranch.Items.Count; i++)
                            if (string.Equals(cboBranch.Items[i].ToString(), anterior, StringComparison.OrdinalIgnoreCase))
                            { idx = i; break; }
                    }
                    cboBranch.SelectedIndex = idx >= 0 ? idx : 0;
                    if (statusLbl.Length > 0) statusLbl[0].Text = ramas.Count + " rama(s) encontrada(s).";
                }
            }
            catch (Exception ex)
            {
                LogMsg("Error al consultar ramas: " + ex.Message);
                if (statusLbl.Length > 0) statusLbl[0].Text = "Error: " + ex.Message;
            }
            finally
            {
                cboBranch.Enabled = true;
            }
        }

        private void BtnSalida_Click(object sender, EventArgs e)
        {
            using (var dlg = new SaveFileDialog())
            {
                dlg.Filter = "Documento PDF (*.pdf)|*.pdf";
                dlg.FileName = "REPORTE_CAMBIOS.pdf";
                if (dlg.ShowDialog(this) == DialogResult.OK) txtSalida.Text = dlg.FileName;
            }
        }

        private void LogMsg(string msg)
        {
            if (txtLog == null || string.IsNullOrEmpty(msg)) return;
            if (txtLog.InvokeRequired)
            {
                txtLog.BeginInvoke((Action)(() => LogMsg(msg)));
                return;
            }
            string ts = DateTime.Now.ToString("HH:mm:ss");
            txtLog.AppendText("[" + ts + "] " + msg + "\r\n");
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
                if (txtProj.Text.Trim().Length == 0) throw new ArgumentException("Indique la URL remota o carpeta local del proyecto (SVN o Git).");
                if (txtDesde.Text.Trim().Length == 0) throw new ArgumentException("Indique el valor \"Desde\" (fecha o revision).");

                var opt = new ReportOptions();
                opt.ProjectPath = txtProj.Text.Trim();
                opt.Desde = txtDesde.Text.Trim();
                opt.Hasta = txtHasta.Text.Trim().Length > 0 ? txtHasta.Text.Trim() : "HEAD";
                opt.Modulos = Texto.SplitLista(TextoReal(txtMods));
                opt.Extensiones = Texto.SplitLista(txtExts.Text);
                opt.Salida = txtSalida.Text.Trim();
                opt.Autor = txtAutor.Text.Trim();
                opt.Orden = cboOrden.SelectedIndex == 1 ? "desc" : "asc";
                opt.ExcluirMvnRelease = chkExclRel.Checked;
                opt.ExcluirMvnPrepare = chkExclPrep.Checked;
                opt.IncluirResumen = chkResumen.Checked;
                opt.Branch = cboBranch.SelectedItem != null ? cboBranch.SelectedItem.ToString() : "";

                GuardarConfig();
                txtLog.Text = "";
                LogMsg("Iniciando generacion de reporte...");
                LogMsg("Proyecto: " + opt.ProjectPath);
                LogMsg("Rango: " + opt.Desde + " -> " + opt.Hasta);
                if (opt.Branch.Length > 0) LogMsg("Rama: " + opt.Branch);
                SetBusy(true);
                pb.Value = 0;
                bw.RunWorkerAsync(opt);
            }
            catch (Exception ex)
            {
                LogMsg("ERROR: " + ex.Message);
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
            txtAutor.Enabled = !busy;
            cboOrden.Enabled = !busy; cboBranch.Enabled = !busy;
            chkExclRel.Enabled = !busy; chkExclPrep.Enabled = !busy;
            btnDir.Enabled = !busy; btnSalida.Enabled = !busy; btnBranch.Enabled = !busy;
            chkResumen.Enabled = !busy;
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
            string msg = (string)(e.UserState ?? "");
            lblEstado.Text = msg;
            LogMsg(msg);
        }

        private void Bw_RunWorkerCompleted(object sender, RunWorkerCompletedEventArgs e)
        {
            SetBusy(false);
            if (e.Error is OperationCanceledException)
            {
                LogMsg("Operacion cancelada por el usuario.");
                lblEstado.Text = "Operacion cancelada.";
                pb.Value = 0;
                return;
            }
            if (e.Error != null)
            {
                LogMsg("ERROR: " + e.Error.Message);
                lblEstado.Text = "Error.";
                MessageBox.Show(this, e.Error.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            var res = (ReportResult)e.Result;
            pb.Value = 100;
            lblEstado.Text = "Listo: " + res.Salida;
            LogMsg("Reporte generado: " + res.Salida);
            LogMsg("Revisiones: " + res.Revisiones + ", Archivos: " + res.Archivos + ", Bloques: " + res.Bloques);
            if (res.SinCambios.Count > 0) LogMsg("Sin cambios: " + string.Join(", ", res.SinCambios));

            using (var rf = new ResultForm(res))
                rf.ShowDialog(this);
        }
    }

    internal class ResultForm : Form
    {
        public ResultForm(ReportResult res)
        {
            Text = "Reporte generado";
            ClientSize = new Size(380, 230);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterParent;
            Font = new Font("Segoe UI", 9f);
            ShowInTaskbar = false;

            var lbl = new Label();
            lbl.Text = "Reporte generado. Revisiones: " + res.Revisiones + ", Archivos: " + res.Archivos + ", Bloques: " + res.Bloques;
            lbl.Location = new Point(15, 15);
            lbl.Size = new Size(350, 40);
            Controls.Add(lbl);

            var btnVerHtml = new Button();
            btnVerHtml.Text = "Ver HTML";
            btnVerHtml.Location = new Point(15, 60);
            btnVerHtml.Size = new Size(170, 30);
            btnVerHtml.Click += delegate { try { Process.Start(res.Salida); } catch { } };
            Controls.Add(btnVerHtml);

            var btnGuardarHtml = new Button();
            btnGuardarHtml.Text = "Guardar HTML...";
            btnGuardarHtml.Location = new Point(195, 60);
            btnGuardarHtml.Size = new Size(170, 30);
            btnGuardarHtml.Click += delegate
            {
                using (var sfd = new SaveFileDialog())
                {
                    sfd.Filter = "Archivo HTML (*.html)|*.html";
                    sfd.FileName = "REPORTE_CAMBIOS.html";
                    if (sfd.ShowDialog(this) == DialogResult.OK)
                    {
                        File.Copy(res.Salida, sfd.FileName, true);
                        MessageBox.Show(this, "HTML guardado.", "OK", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                }
            };
            Controls.Add(btnGuardarHtml);

            var btnExportarPdf = new Button();
            btnExportarPdf.Text = "Exportar PDF...";
            btnExportarPdf.Location = new Point(15, 100);
            btnExportarPdf.Size = new Size(170, 30);
            btnExportarPdf.Click += delegate
            {
                using (var sfd = new SaveFileDialog())
                {
                    sfd.Filter = "Documento PDF (*.pdf)|*.pdf";
                    sfd.FileName = "REPORTE_CAMBIOS.pdf";
                    if (sfd.ShowDialog(this) == DialogResult.OK)
                    {
                        try
                        {
                            Engine.ExportarPdf(res.Salida, sfd.FileName);
                            MessageBox.Show(this, "PDF exportado correctamente.", "OK", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        }
                        catch (Exception ex)
                        {
                            MessageBox.Show(this, "Error al exportar PDF: " + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                    }
                }
            };
            Controls.Add(btnExportarPdf);

            var btnGuardarZip = new Button();
            btnGuardarZip.Text = "Guardar ZIP...";
            btnGuardarZip.Location = new Point(195, 100);
            btnGuardarZip.Size = new Size(170, 30);
            btnGuardarZip.Click += delegate
            {
                using (var sfd = new SaveFileDialog())
                {
                    sfd.Filter = "Archivo ZIP (*.zip)|*.zip";
                    sfd.FileName = "REPORTE_CAMBIOS.zip";
                    if (sfd.ShowDialog(this) == DialogResult.OK)
                    {
                        try
                        {
                            string pdfTmp = Path.Combine(Path.GetTempPath(), "RepCambios_" + Guid.NewGuid().ToString("N") + ".pdf");
                            Engine.ExportarPdf(res.Salida, pdfTmp);
                            if (File.Exists(sfd.FileName)) File.Delete(sfd.FileName);
                            using (var fs = new FileStream(sfd.FileName, FileMode.Create))
                            using (var za = new ZipArchive(fs, ZipArchiveMode.Create))
                            {
                                za.CreateEntryFromFile(res.Salida, Path.GetFileName(res.Salida));
                                za.CreateEntryFromFile(pdfTmp, Path.GetFileNameWithoutExtension(res.Salida) + ".pdf");
                            }
                            try { File.Delete(pdfTmp); } catch { }
                            MessageBox.Show(this, "ZIP guardado correctamente (HTML + PDF).", "OK", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        }
                        catch (Exception ex)
                        {
                            MessageBox.Show(this, "Error al crear ZIP: " + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                    }
                }
            };
            Controls.Add(btnGuardarZip);

            var btnCerrar = new Button();
            btnCerrar.Text = "Cerrar";
            btnCerrar.Location = new Point(140, 145);
            btnCerrar.Size = new Size(100, 30);
            btnCerrar.Click += delegate { Close(); };
            Controls.Add(btnCerrar);
        }
    }

    internal static class Program
    {
        [DllImport("kernel32.dll")]
        private static extern bool AttachConsole(int dwProcessId);
        private const int ATTACH_PARENT_PROCESS = -1;

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [STAThread]
        private static int Main(string[] args)
        {
            bool gui = args.Length == 0 || args.Any(a => a.Equals("-Gui", StringComparison.OrdinalIgnoreCase));
            if (gui)
            {
                try { SetProcessDPIAware(); } catch { }
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
                Console.WriteLine("HTML generado    : " + res.Salida);
                Console.WriteLine("Revisiones       : " + res.Revisiones);
                Console.WriteLine("Archivos con diff: " + res.Archivos);
                Console.WriteLine("Bloques de cambio: " + res.Bloques);
                if (res.SinCambios.Count > 0)
                    Console.WriteLine("Sin cambios      : " + string.Join(", ", res.SinCambios));
                if (opt.AbrirAlTerminar)
                {
                    try { Process.Start(res.Salida); } catch { }
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
                   "  ReporteCambios.exe                          (interfaz grafica)\r\n" +
                   "  ReporteCambios.exe -ProjectPath <url|carpeta> -Desde <fecha|rev>\r\n" +
                   "      [-Hasta <fecha|rev|HEAD>] [-Archivos \"A,B,C\"] [-Extensiones \"BAS,DAT\"]\r\n" +
                   "      [-Salida archivo.html] [-SinResumen] [-AbrirAlTerminar]\r\n" +
                   "      [-Autor \"Nombre\"] [-Vcs auto|svn|git] [-Orden asc|desc]\r\n" +
                   "      [-Branch <rama>] [-ExcluirMvnRelease] [-ExcluirMvnPrepare]\r\n" +
                   "Notas: -Modulos es alias de -Archivos. Sin -Archivos y/o sin -Extensiones\r\n" +
                   "       se incluyen TODOS los archivos / cualquier extension.\r\n" +
                   "       Soporta SVN (URL o working copy) y Git (URL remota git@... o carpeta local).\r\n" +
                   "       Git remoto requiere acceso SSH/HTTPS configurado en su equipo.\r\n" +
                   "       Si usa carpeta local, se extrae la URL del repositorio remoto automaticamente.\r\n" +
                   "Dependencias: svn.exe y/o git.exe en el PATH. PDF/ZIP disponibles desde la GUI.";
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
                else if (a == "-autor") opt.Autor = Next(args, ref i, a);
                else if (a == "-vcs") opt.Vcs = Next(args, ref i, a);
                else if (a == "-orden") opt.Orden = Next(args, ref i, a);
                else if (a == "-branch") opt.Branch = Next(args, ref i, a);
                else if (a == "-excluirmvnrelease") opt.ExcluirMvnRelease = true;
                else if (a == "-excluirmvnprepare") opt.ExcluirMvnPrepare = true;
                else if (a == "-zip") opt.ExportarZip = true;
                else if (a == "-sinresumen") opt.IncluirResumen = false;
                else if (a == "-abriralterminar") opt.AbrirAlTerminar = true;
                else if (a == "-pdf") opt.ExportarPdf = true;
                else if (a == "-salidapdf") { opt.SalidaPdf = Next(args, ref i, a); opt.ExportarPdf = true; }
                else if (a == "-gui") { }
                else throw new ArgumentException("Parametro no reconocido: " + args[i]);
            }
            if (opt.ProjectPath.Trim().Length == 0) throw new ArgumentException("Falta -ProjectPath (URL remota o carpeta local del proyecto SVN/Git).");
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
