# fgljp/fglssh
Genero GAS like proxy to run GBC programs from the command line
fgl (j)ava (p)roxy 
Uses loads of IMPORT JAVA 
Use this branch only if your Genero version is < 4.01.03

(4.01.03 did introduce util.Channels.select + a bunch of other Channel methods,
see https://4js.com/online_documentation/fjs-fgl-manual-html/?path=fjs-fgl-manual#fgl-topics/c_fgl_ext_util_Channels_methods.html) 

# Motivation

If you search an easy command line tool to run GBC in your desktop browser then fgljp is the right tool for you.

It is (almost) as easy as 
```
$ fglrun prog arg1 arg2
```
, just call your program with

```
$ fgljp prog arg1 arg2
```
If you start fgljp with a Genero program argument fgljp emulates a GAS running on your client machine.
This assumes that the fglrun to work with runs also locally on your client machine.


Starting fgljp *without* a program argument turns fgljp into a GDC equivalent:
It then listens on 6400 for incoming connections and opens the browser with
GBC.
GBC shows the Genero program caused by a local or remote invocation of fglrun.

```
$ ./fgljp &
{"port":6400,"FGLSERVER":"localhost:0","pid":18092}
[1] 18120
$ fglcomp demo && fglform demo && fglrun demo
```

This is the remote mode. There is also no GAS needed to let the remote mode work.
In comparison with GDC the difference is that no (potentially dangerous) GDC frontcalls are possible (yet) which makes fgljp a very safe replacement to develop GBC programs intended to run in the browser.
There is literally no difference vs a GBC using GAS on a remote server.
Obviously you need an fglrun on the *client* side to make fgljp working, but there is no database needed.

By default fgljp listens on the loopback interface only.
Only when starting with the -a argument it listens on the ANY interface (and you will very likely get firewall warnings then).

To be able to work conveniently with remote hosts there is the `fglssh` command in this repository: it establishes a secure ssh tunnel to your Genero development machine and exports FGLSERVER to the remote side.

Prerequisites:
FGL >= 3.10
JAVA >= 9
(Linux: xdg-open in addition)
on your desktop machine


# How it works

1. fgljp starts the given program and implements an http server as well as a socket server for the fglrun GUI output (both listening on the same port: fgljp auto senses the protocol).
2. It opens your default browser pointing to the suitable URL: voila, you should see the app, and DISPLAY statements appear on stdout like via GDC.
3. In remote mode (start without program arguments) it listens for incoming connections. As soon as a fglrun process connects it does the same as GDC in UR mode: downloading the GBC and providing a http URL for GBC to work with.
The difference is: it uses your system browser.
Under the hood fgljp implements the encapsulated VM protocol using filetransfer in order to achive that,
it emulates hence a GDC.

# Installation

You don't necessarily need to install fgljp.
If you did check out this repository you can call
```
$ <path_to_this_repository>/fgljp ?options? ?yourprogram? ?arg? ?arg?
```

Windows
```
C:> <path_to_this_repository>\fgljp ?options? ?yourprogram? ?arg? ?arg?
```

and it uses the fglcomp/fglrun in your PATH to compile and run fgljp.
Of course you can add also <path_to_this_repository> in your PATH to invoke fgljp without the path.

# Windows

On Windows the command to invoke is simply
```
C:\<somepath>\fgljp>fgljp
```
(it's a straight .bat file compiling/running fgljp)
you can set the BROWSER variable to the following values to start another
browser than the default one:
chrome,firefox,edge (IE: not supported)
```
set BROWSER=firefox && fgljp
```

# Mac

possible BROWSER values: chrome,firefox,safari
```
BROWSER=chrome && fgljp
```

# fglssh

fglssh is another small tool on top of fgljp which logs you in via ssh
on your Genero development machine.
It starts first fgljp in the background and exports FGLSERVER to the right value(by using auto portwarding) to be able to back connect to the fgljp running on your desktop.

Using OpenSSH:

If you have an OpenSSH client on your desktop machine installed (On Mac/Linux: preinstalled, Windows 10 or bigger: needs to be installed) and a bash on the remote side then invocation is pretty simple.
(Windows powershell with admin rights:
Add-WindowsCapability -Online -Name OpenSSH.Client
installs or query:
Get-WindowsCapability -Online | ? Name -like 'OpenSSH.Client*'
)

```
$ fglssh -b <your-genero-dev-machine>
echo $FGLSERVER
localhost:xxxxx
fglrun <program>
```
The Genero/GBC program appears in you desktop browser using the remote side fglrun/GBC.
Your remote side fglrun/fglcomp/GBC version doesn't need to match the one on your desktop, both are independent. The desktop side is only responsible for translating the protocol to the browser. The desktop's GBC (if present) isn't used at all.

If you don't have a bash at the remote side you need to edit the server sides sshd\_config file to enable the transmission of the FGLSERVER and \_FGLFEID  environment variable.
sshd\_config must contain a line
```
AcceptEnv FGLSERVER _FGLFEID _FGLFEID2
```
(You can have multiple AcceptEnv lines, see https://serverfault.com/questions/703315/how-configure-environment-variable-with-acceptenv)
Restart your sshd after the change.
(Linux: too much variants, google it)
(Mac: `sudo launchctl stop sshd&&launchctl start sshd`)
(Windows: `powershell -Command "& {Stop-Service sshd;Start-Service sshd}"`)

`$ fglssh <your-genero-dev-machine>`
should now export FGLSERVER to the environment regardless if bash,ash,ksh,csh or windows cmd is on the remote side
If you use a cleartext password you need to enter it twice when you have a windows desktop, so better to have a public ssh key. 

Using fgltty:
fgltty is the helper ssh program delivered with the GDC and fglssh can use that too instead of an OpenSSH client

```
fglssh -y "c:\Program Files\FourJs\gdc3.20\bin\fgltty" -x <yourpassword> -b usr@<your-genero-dev-machine>
```
invokes first fgljp, then fgltty and opens up the graphical terminal window of fgltty you may know from GDC ssh direct shortcut configurations.
If -b (or --bash) is used because bash is present remotely, FGLSERVER is automatically set and you have a login bash.

In all other cases you need to use one of the known 'direct shortcut tags' described in tge GDC manual (see http://4js.com/online_documentation/fjs-gdc-manual-html/#gdc-topics/t_gdc_applications_shortcuts_creating_direct.html)

# Known problems
Currently its impossible to terminate fgljp with Control-c in the windows console (see FGL issue FGL-5697).
One needs to use `taskkill /f /im fglrun.exe` currently to terminate the process.
