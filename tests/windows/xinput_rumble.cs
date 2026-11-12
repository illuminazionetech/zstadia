// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Z Stadia contributors
//
// A tiny Windows program that asks for rumble the way most Windows games do,
// through XInput. Run it inside the same Wine your games use to check the whole
// chain: XInput -> Wine winebus -> SDL -> Stadia controller. See
// docs/WINDOWS_GAMES.md for how to build and run it with Wine's own compiler.

using System;
using System.Runtime.InteropServices;
using System.Threading;

static class XInputRumbleTest
{
    [StructLayout(LayoutKind.Sequential)]
    struct Vibration { public ushort Left; public ushort Right; }

    [StructLayout(LayoutKind.Sequential)]
    struct Gamepad { public ushort Buttons; public byte LeftTrigger, RightTrigger; public short LX, LY, RX, RY; }

    [StructLayout(LayoutKind.Sequential)]
    struct State { public uint Packet; public Gamepad Pad; }

    [DllImport("xinput1_3.dll")] static extern uint XInputGetState(uint user, out State state);
    [DllImport("xinput1_3.dll")] static extern uint XInputSetState(uint user, ref Vibration vibration);

    static void Set(uint user, ushort left, ushort right, int ms)
    {
        var v = new Vibration { Left = left, Right = right };
        uint r = XInputSetState(user, ref v);
        Console.WriteLine("  XInputSetState({0}, left {1}, right {2}) = {3}", user, left, right, r == 0 ? "OK" : "error " + r);
        Thread.Sleep(ms);
    }

    static int Main()
    {
        int found = -1;
        for (uint i = 0; i < 4; i++)
        {
            State s;
            uint r = XInputGetState(i, out s);
            Console.WriteLine("XInput slot {0}: {1}", i, r == 0 ? "controller connected" : "empty");
            if (r == 0 && found < 0) found = (int)i;
        }
        if (found < 0) { Console.WriteLine("FAIL no controller visible to XInput"); return 1; }
        uint user = (uint)found;
        Console.WriteLine("Rumble on slot {0}: left (strong), right (weak), both", user);
        Set(user, 65535, 0, 500);
        Set(user, 0, 0, 300);
        Set(user, 0, 65535, 500);
        Set(user, 0, 0, 300);
        Set(user, 40000, 40000, 700);
        Set(user, 0, 0, 100);
        Console.WriteLine("done");
        return 0;
    }
}
