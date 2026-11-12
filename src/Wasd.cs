// WASD map movement for Hearts of Iron IV (the game itself only pans with the arrow keys).
// Runs as "<launcher>.exe /wasd", started by the engine right after the game starts; ends on its own once no
// hoi4.exe has been running for a short while. Only while a hoi4.exe window is in front:
//   W/A/S/D (no Shift/Ctrl/Alt)  ->  Up/Left/Down/Right arrow keys
//   standby                      ->  from the start (main menu, lobby, picking a country) and after every Esc (the save
//                                    screen is behind Esc): a quick tap types the letter, holding the key for a moment
//                                    starts panning and ends standby
//   console key (under Esc)      ->  the game's console opens: W/A/S/D type letters until it is pressed again
//   F11                          ->  turns WASD off/on (e.g. for chat)
// Everything else, and every other program, is left alone.
//
// Windows silently removes a low-level keyboard hook that answers too slowly (easy while HOI4 loads and eats the
// CPU), so the hook itself only does cheap work: whether HOI4 is in front is worked out by a timer, the code is
// compiled before the first key press, the helper runs at raised priority, and the hook is re-installed every
// 30 s so a dropped hook comes back on its own.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Media;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

static class Wasd
{
    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int idHook, HookProc fn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, INPUT[] inputs, int size);

    [StructLayout(LayoutKind.Sequential)] struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public InputUnion u; }

    const int WH_KEYBOARD_LL = 13, VK_F11 = 0x7A, VK_ESCAPE = 0x1B;
    const uint SCAN_CONSOLE = 0x29;          // the key under Esc (` ~ on US keyboards, ^ on German ones), by position not letter
    const uint LLKHF_EXTENDED = 0x01, LLKHF_INJECTED = 0x10, LLKHF_UP = 0x80, KEYEVENTF_EXTENDEDKEY = 0x1, KEYEVENTF_KEYUP = 0x2;
    const int HOLD_MS = 250;                 // in standby a key held this long means "pan"; typing taps are shorter

    class Pend { public uint Vk; public ushort Scan; public int Since; }

    static IntPtr hook = IntPtr.Zero, hMod = IntPtr.Zero;
    static HookProc proc;                    // kept in a field so the garbage collector can't free it
    static bool enabled = true;
    static bool standby = true;              // main menu / lobby / after Esc: taps are letters, a hold starts panning
    static bool typing, consoleKeyDown;      // console open: W/A/S/D are letters (key repeat doesn't flip it back)
    static volatile bool hoiFront;           // set by a timer - never worked out inside the hook
    static readonly HashSet<uint> held = new HashSet<uint>();        // W/A/S/D keys whose arrow is currently pressed
    static readonly List<Pend> pending = new List<Pend>();           // standby: pressed, not yet known if tap or hold
    static readonly HashSet<uint> swallowUp = new HashSet<uint>();   // already typed as a letter: drop the real key-up
    static Action<ushort, ushort, bool, bool> send = SendKey;       // swappable so the stress test can watch without pressing real keys
    static Func<int> now = () => Environment.TickCount;              // swappable for the stress test's clock
    static readonly INPUT[] one = new INPUT[1];
    static readonly int inputSize = Marshal.SizeOf(typeof(INPUT));
    static uint lastPid; static bool lastIsHoi;

    public static void Run()
    {
        bool first; var single = new Mutex(true, "Local\\HOI4WasdMapMovement", out first);
        if (!first) return;                  // another launcher's helper is already doing it
        try { using (var me = Process.GetCurrentProcess()) me.PriorityClass = ProcessPriorityClass.AboveNormal; } catch { }
        // compile everything now, so the first key press doesn't wait for the JIT inside the hook
        foreach (var m in typeof(Wasd).GetMethods(BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public))
            if (!m.IsAbstract && !m.ContainsGenericParameters && (m.Attributes & MethodAttributes.PinvokeImpl) == 0) { try { RuntimeHelpers.PrepareMethod(m.MethodHandle); } catch { } }
        proc = Callback;
        using (var me = Process.GetCurrentProcess()) using (var mod = me.MainModule) hMod = GetModuleHandle(mod.ModuleName);
        Install();
        if (hook == IntPtr.Zero) return;
        UpdateFront();

        // is HOI4 the window in front? (checked here, not in the hook)
        var front = new System.Windows.Forms.Timer { Interval = 150 };
        front.Tick += (s, e) => UpdateFront();
        front.Start();
        // standby: a key that is still down after HOLD_MS starts panning (without waiting for Windows' key repeat)
        var hold = new System.Windows.Forms.Timer { Interval = 50 };
        hold.Tick += (s, e) => CheckPending();
        hold.Start();
        // re-install the hook now and then: Windows may have dropped it without telling us
        var rehook = new System.Windows.Forms.Timer { Interval = 30000 };
        rehook.Tick += (s, e) => { if (held.Count == 0 && pending.Count == 0) Install(); };
        rehook.Start();
        // stay while the game runs: quit after ~20 s without any hoi4.exe (or 4 min if it never showed up)
        DateTime start = DateTime.Now, lastSeen = DateTime.MinValue;
        var life = new System.Windows.Forms.Timer { Interval = 5000 };
        life.Tick += (s, e) => {
            if (Process.GetProcessesByName("hoi4").Length > 0) lastSeen = DateTime.Now;
            bool gone = lastSeen == DateTime.MinValue ? (DateTime.Now - start).TotalMinutes > 4 : (DateTime.Now - lastSeen).TotalSeconds > 20;
            if (gone) { life.Stop(); front.Stop(); hold.Stop(); rehook.Stop(); Application.ExitThread(); }
        };
        life.Start();
        Application.Run();
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        GC.KeepAlive(single);
    }

    // the new hook goes in before the old one comes out, so no key press slips through in between
    static void Install()
    {
        var h = SetWindowsHookEx(WH_KEYBOARD_LL, proc, hMod, 0);
        if (h == IntPtr.Zero) return;
        var old = hook; hook = h;
        if (old != IntPtr.Zero) UnhookWindowsHookEx(old);
    }

    static void UpdateFront()
    {
        uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        if (pid != lastPid) {
            bool isHoi = false;
            try { using (var p = Process.GetProcessById((int)pid)) isHoi = string.Equals(p.ProcessName, "hoi4", StringComparison.OrdinalIgnoreCase); } catch { }
            lastPid = pid; lastIsHoi = isHoi;
        }
        hoiFront = lastIsHoi;
        if (!hoiFront && pending.Count > 0) { foreach (var p in pending) swallowUp.Add(p.Vk); pending.Clear(); }   // switched away mid-press: type nothing
    }
    static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

    // W/A/S/D -> arrow key: virtual-key code + scan code (arrows are "extended" keys)
    static bool Arrow(uint vk, out ushort arrowVk, out ushort scan)
    {
        arrowVk = 0; scan = 0;
        switch (vk) {
            case 0x57: arrowVk = 0x26; scan = 0x48; return true;   // W -> Up
            case 0x41: arrowVk = 0x25; scan = 0x4B; return true;   // A -> Left
            case 0x53: arrowVk = 0x28; scan = 0x50; return true;   // S -> Down
            case 0x44: arrowVk = 0x27; scan = 0x4D; return true;   // D -> Right
        }
        return false;
    }
    static void SendKey(ushort vk, ushort scan, bool up, bool extended)
    {
        one[0].type = 1;
        one[0].u.ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = (extended ? KEYEVENTF_EXTENDEDKEY : 0) | (up ? KEYEVENTF_KEYUP : 0) };
        SendInput(1, one, inputSize);
    }
    static void ReleaseHeld()
    {
        ushort avk, scan;
        foreach (uint vk in new List<uint>(held)) { if (Arrow(vk, out avk, out scan)) send(avk, scan, true, true); }
        held.Clear();
    }
    // standby keys that turned out to be typing: type them as plain letters, in the order they were pressed.
    // A key still physically down gets its real key-up dropped later (its letter is already complete).
    static void TypePending(uint releasing)
    {
        foreach (var p in pending) {
            send((ushort)p.Vk, p.Scan, false, false); send((ushort)p.Vk, p.Scan, true, false);
            if (p.Vk != releasing) swallowUp.Add(p.Vk);
        }
        pending.Clear();
    }
    // standby keys that turned out to be held: pan, and leave standby
    static void StartPan()
    {
        ushort avk, scan;
        foreach (var p in pending) { if (Arrow(p.Vk, out avk, out scan)) { held.Add(p.Vk); send(avk, scan, false, true); } }
        pending.Clear(); standby = false;
    }
    static int PendingIndex(uint vk) { for (int i = 0; i < pending.Count; i++) if (pending[i].Vk == vk) return i; return -1; }
    static void CheckPending() { if (pending.Count > 0 && now() - pending[0].Since >= HOLD_MS) StartPan(); }

    static IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0) {
            var k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            bool injected = (k.flags & LLKHF_INJECTED) != 0, up = (k.flags & LLKHF_UP) != 0;
            ushort avk, scan;
            if (!injected) {
                bool wasd = Arrow(k.vkCode, out avk, out scan);
                bool plain = enabled && !typing && hoiFront && !Down(0x10) && !Down(0x11) && !Down(0x12);
                // another key while standby keys wait: they were typing - type them first, then this key, in that order
                bool replay = !up && pending.Count > 0 && !(wasd && plain && standby);
                if (replay) TypePending(0);

                // the console key opens and closes the game's console; Esc closes the console and menus and opens the
                // menu with the save screen - standby. Both keys still go on to the game.
                if (k.scanCode == SCAN_CONSOLE) {
                    if (up) consoleKeyDown = false;
                    else if (!consoleKeyDown && hoiFront) { consoleKeyDown = true; typing = !typing; if (typing) ReleaseHeld(); else standby = false; }
                }
                if (!up && k.vkCode == VK_ESCAPE && hoiFront) { ReleaseHeld(); typing = false; standby = true; }

                if (k.vkCode == VK_F11 && hoiFront) {
                    if (!up) {
                        enabled = !enabled; standby = false;
                        ReleaseHeld();
                        bool nowOn = enabled;
                        ThreadPool.QueueUserWorkItem(_ => { if (nowOn) SystemSounds.Asterisk.Play(); else SystemSounds.Hand.Play(); });
                    }
                    return (IntPtr)1;
                }

                if (wasd) {
                    if (up && swallowUp.Remove(k.vkCode)) return (IntPtr)1;                        // its letter was already typed
                    // a key we turned into an arrow is always released as that arrow, so nothing gets stuck
                    if (up && held.Remove(k.vkCode)) { send(avk, scan, true, true); return (IntPtr)1; }
                    int pi = PendingIndex(k.vkCode);
                    if (up && pi >= 0) { TypePending(k.vkCode); return (IntPtr)1; }                // a quick tap: the letter
                    if (!up && pi >= 0) { if (now() - pending[pi].Since >= HOLD_MS) StartPan(); return (IntPtr)1; }   // key repeat while waiting
                    if (!up && held.Contains(k.vkCode)) { send(avk, scan, false, true); return (IntPtr)1; }       // key repeat
                    if (!up && plain) {
                        if (standby) { pending.Add(new Pend { Vk = k.vkCode, Scan = (ushort)k.scanCode, Since = now() }); return (IntPtr)1; }
                        held.Add(k.vkCode); send(avk, scan, false, true); return (IntPtr)1;
                    }
                }
                if (replay) { send((ushort)k.vkCode, (ushort)k.scanCode, false, (k.flags & LLKHF_EXTENDED) != 0); return (IntPtr)1; }
            }
        }
        return CallNextHookEx(hook, nCode, wParam, lParam);
    }
}
