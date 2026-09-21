using dRz.drzTools.NC;
using HostMgd.ApplicationServices;
using HostMgd.EditorInput;
using Rtm = Teigha.Runtime;

[assembly: Rtm.ExtensionApplication(typeof(EntryPoint))]

namespace dRz.drzTools.NC
{
    internal sealed class EntryPoint : Rtm.IExtensionApplication

    {
        public void Initialize()
        {
            string message = "Hello drzTools";
            Document document = Application.DocumentManager.MdiActiveDocument;
            if (document != null)
            {
                Editor editor = document.Editor;

                editor.WriteMessage(message);
            }
            else
            {
                Application.ShowAlertDialog(message);
            }
        }

        /// <summary>
        /// Код данного метода выполняется при завершении работы AutoCAD.
        /// </summary>
        public void Terminate()
        {
        }
    }
}