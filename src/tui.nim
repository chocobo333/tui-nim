
import strutils
import strformat
import sequtils
import bitops

import termios
import terminal

import posix

import std/exitprocs

import sugar


proc getchar():int {.importc:"getchar", header: "<stdio.h>", discardable.}
proc ungetc(a: int, b: File): int {.importc:"ungetc", header: "<stdio.h>", discardable.}
proc kbhit*(): bool =
    var
        oldt, newt: Termios
        ch: int
        oldf: int
    discard tcGetAttr(STDIN_FILENO, oldt.addr)
    newt = oldt
    newt.c_lflag.clearMask(bitor(ICANON, ECHO))
    discard tcSetAttr(STDIN_FILENO, TCSANOW, newt.addr)
    oldf = fcntl(STDIN_FILENO, F_GETFL, 0)
    discard fcntl(STDIN_FILENO, F_SETFL, bitor(oldf, O_NONBLOCK))
    ch = getchar()
    discard tcSetAttr(STDIN_FILENO, TCSANOW, oldt.addr);
    discard fcntl(STDIN_FILENO, F_SETFL, oldf);
    
    if ch != -1:
        discard ungetc(ch, stdin)
        true
    else:
        false


{.experimental: "notnil".}

type
    Rect = object
        x, y: int
        w, h: int
    Position = object
        line, col: int
    Window = ref object of RootObj
        rect: Rect
        parent: Window
        children: seq[Window]
        buffer: seq[string] # lines
        curpos: Position
        show: bool

proc newRect(x, y, w, h: int): Rect =
    Rect(x: x, y: y, w: w, h: h)

proc `x`*(self: Window): int = self.rect.x
proc `y`*(self: Window): int = self.rect.y
proc `w`*(self: Window): int = self.rect.w
proc `h`*(self: Window): int = self.rect.h

proc `x=`*(self: Window, val: int) = self.rect.x = val
proc `y=`*(self: Window, val: int) = self.rect.y = val
proc `w=`*(self: Window, val: int) = self.rect.w = val
proc `h=`*(self: Window, val: int) = self.rect.h = val

proc show*(self: Window): bool = self.show
proc show*(self: Window, b: bool) = self.show = b

method getBuffer*(self: Window): seq[string] {.base.} = self.buffer[0..<min(self.buffer.len, self.h)]

var
    rootwindow: Window
    screenbuffer: seq[string] = @[""]
    rootInitialized = false

proc initRootWindow*: Window =
    if rootInitialized:
        rootwindow
    else:
        rootInitialized = true
        let
            x = 0
            y = 0
            w = terminalWidth()
            h = terminalHeight()
        Window(rect: newRect(x, y, w, h), parent: nil, show: true)
rootwindow = initRootWindow()

proc newWindow*(x, y, w, h: int, parent: Window not nil = rootwindow): Window =
    Window(rect: newRect(x, y, w, h), parent: parent, show: true)


proc enterAlternativeScreen* =
    stdout.write "\e[?1049h"
proc exitAlternativeScreen* =
    stdout.write "\e[?1049l"
proc nocursor*(b: bool = on) =
    if b:
        stdout.write "\e[?25l"
    else:
        stdout.write "\e[?25h"
proc noecho*(b: bool = on) =
    var
        oldb {.global.}: bool = off
        t {.global.}: Termios
    if b == oldb:
        return
    if b:
        discard tcGetAttr(STDIN_FILENO, t.addr)
        var newt = t
        # newt.c_lflag.clearMask(bitor(ECHO, ECHONL, ISIG, IEXTEN))
        newt.c_lflag.clearMask(bitor(ECHO, ECHONL, ICANON, ISIG, IEXTEN))
        discard tcSetAttr(STDIN_FILENO, TCSANOW, newt.addr)
    else:
        discard tcSetAttr(STDIN_FILENO, TCSANOW, t.addr)
    oldb = b
proc mouseevent(b: bool = on) =
    var
        oldb {.global.}: bool = off
    if b == oldb:
        return
    if b:
        stdout.write "\e[?1000h\e[?1003h\e[?1006h"
    else:
        stdout.write "\e[?1000l\e[?1003l\e[?1006l"
    oldb = b


var tcs: seq[Termios]
proc tcSave*() =
    tcs.setLen tcs.len+1
    discard tcGetAttr(STDIN_FILENO, tcs[^1].addr)
proc tcPop*() =
    discard tcSetAttr(STDIN_FILENO, TCSANOW, tcs[^1].addr)
    discard tcs.pop()


proc startTui*(): Window =
    tcSave()
    enterAlternativeScreen()
    nocursor on
    noecho on
    mouseevent on
    rootwindow
proc endTui* =
    exitAlternativeScreen()
    nocursor off
    noecho off
    mouseevent off
    tcPop()

proc deinitTui =
    endTui()
proc initTui*(): Window =
    addExitProc deinitTui
    startTui()

proc difplay*(buffer: seq[string]) =
    var res = newStringOfCap(100)
    res.add "\e[1;1H"
    for line, (oldb, newb) in zip(screenbuffer, buffer):
        var col = 0
        let
            minlen = min(oldb.len, newb.len)
            # maxlen = max(oldb.len, newb.len)
        while col < minlen:
            var i = 0
            while col < minlen and oldb[col] == newb[col]:
                inc col
                inc i
            if i > 0:
                res.add &"\e[{i}C"
                i = 0
            while col < minlen and oldb[col] != newb[col]:
                inc col
                inc i
            if i > 0:
                res.add newb[col-i..<col]
        if oldb.len < newb.len:
            res.add newb[col..^1]
        else:
            res.add "\e[K"
        res.add "\e[E"
    if screenbuffer.len < buffer.len:
        res.add buffer[screenbuffer.len..^1].join("\e[E")
    else:
        res.add "\e[J"
    stdout.write res
    screenbuffer = buffer

proc cliped(self: seq[string], rect: Rect): seq[string] =
    var i = 0
    for e in self[0..<min(self.len, rect.h)]:
        if e.len < rect.w:
            result.add e
            inc i
            if i >= rect.h:
                return
        else:
            result.add e[0..<rect.w]
            inc i
            if i >= rect.h:
                return
            for j in countup(rect.w, e.len, rect.w-1):
                result.add " " & e[j..<min(j+rect.w-1, e.len)]
                inc i
                if i >= rect.h:
                    return

proc display*(win: Window = rootwindow) =
    var mergedbuffer: seq[string]
    if win.show:
        mergedbuffer = win.getBuffer.cliped(win.rect)
    else:
        # eraseScreen()
        return
    if mergedbuffer.len == 0:
        # eraseScreen()
        return
    difplay(mergedbuffer)

proc writeAline(self: Window, s: string) =
    var
        x: int = self.curpos.line
        y: int = self.curpos.col
    if self.buffer.len-1 < x:
        self.buffer.setLen(x+1)
    if self.buffer[x].len-1 < y + s.len:
        self.buffer[x].add spaces(y - self.buffer[x].len + s.len)
    self.buffer[x][y..<y+s.len] = s
    self.curpos.col += s.len
proc writeAline(self: Window, s: string, x, y: int) =
    if self.buffer.len-1 < x:
        self.buffer.setLen(x+1)
    if self.buffer[x].len-1 < y + s.len:
        self.buffer[x].add spaces(y - self.buffer[x].len + s.len)
    self.buffer[x][y..<y+s.len] = s

proc flatten[T](self: seq[seq[T]]): seq[T] =
    for e in self:
        result.add e
proc writeLineRect(self: Window, s: varargs[string]) =
    var
        s = s.mapIt(it.splitLines).flatten
    for s in s:
        self.writeAline s
        inc self.curpos.line
proc writeRect(self: Window, s: varargs[string]) =
    self.writeLineRect s
    dec self.curpos.line
proc writeLine(self: Window, s: varargs[string]) =
    var
        s = s.mapIt(it.splitLines).flatten
    for s in s:
        self.writeAline s
        inc self.curpos.line
        self.curpos.col = 0
proc write(self: Window, s: varargs[string]) =
    var
        s = s.mapIt(it.splitLines).flatten
    self.writeAline s[0]
    for s in s[1..^1]:
        inc self.curpos.line
        self.curpos.col = 0
        self.writeAline s

proc move(self: Window, y, x: int) =
    self.curpos = Position(line: y, col: x)

type
    Modifier = enum
        Shift
        Meta
        Ctrl
    KeyKind = enum
        None
        A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z
        N0, N1, N2, N3, N4, N5, N6, N7, N8, N9
        MB1, MB2, MB3, MBRelease, MBS, MBIS
    Key = (set[Modifier], KeyKind)
    Mouse = object
        x, y: int
        drag: bool # if button is pressing, true, if not false

var mouse = Mouse()

proc getMouse*(): Mouse = mouse


converter toKey*(a: KeyKind): Key = ({}, a)
template `.`(typ: typedesc[Key], a: KeyKind): Key = ({}, a)
template `.`(modirfier: Modifier, a: KeyKind): Key = (modirfier, a)

{.experimental: "caseStmtMacros".}

import std/macros

macro `match`(n: Key): untyped =
  result = newTree(nnkIfStmt)
  let selector = n[0]
  for i in 1 ..< n.len:
    let it = n[i]
    case it.kind
    of nnkElse, nnkElifBranch, nnkElifExpr, nnkElseExpr:
      result.add it
    of nnkOfBranch:
      for j in 0..it.len-2:
        let cond = newCall("==", selector, it[j])
        result.add newTree(nnkElifBranch, cond, it[^1])
    else:
      error "custom 'case' for tuple cannot handle this node", it

proc readuntil*(ch: char): string =
    # note: consume ch
    while true:
        let c = getch()
        if c == ch:
            break
        result.add c
proc readuntil*(ch: set[char]): string =
    # note: consume ch
    while true:
        let c = getch()
        if c in ch:
            break
        result.add c
proc getkey*(): Key =
    let ch = getch()
    case ch
    of '\e': # reporting
        let ch = getch()
        case ch
        of '[': # CSI
            let ch = getch()
            case ch
            of '<': # mouse reporting
                var
                    btn = readuntil(';').parseInt
                    px = readuntil(';').parseInt
                    (py, released) = block:
                        var
                            res = ""
                            released: bool = false
                        while true:
                            let c = getch()
                            if c == 'M':
                                break
                            if c == 'm':
                                released = true
                                break
                            res.add c
                        (res.parseInt, released)
                        
                mouse.x = px
                mouse.y = py
                let
                    (
                        scroll,
                        moving,
                        ctrl,
                        meta,
                        shift
                    ) = (
                            btn.testBit(6),
                            btn.testBit(5),
                            btn.testBit(4),
                            btn.testBit(3),
                            btn.testBit(2),
                        )
                var modifier: set[Modifier] = {}
                if ctrl: modifier.incl Ctrl
                if meta: modifier.incl Meta
                if shift: modifier.incl Shift

                btn = btn.masked(0b11)
                mouse.drag = btn != 3 and not scroll
                let res = if scroll:
                    KeyKind(KeyKind.MBS.ord + btn)
                else:
                    KeyKind(KeyKind.MB1.ord + btn)
                rootwindow.move(0, 0)
                rootwindow.writeLine fmt"{res}{mouse.drag}{released}({px}, {py})"
                return (modifier, res)
            else:
                discard
        else:
            discard
    of 'a'..'z':
        return KeyKind(KeyKind.A.ord + (ch.ord - 'a'.ord))
    of 'A'..'Z':
        return ({Shift}, KeyKind(KeyKind.A.ord + (ch.ord - 'A'.ord)))
    of '0'..'9':
        return KeyKind(KeyKind.N0.ord + (ch.ord - '0'.ord))
    else:
        return Key.None
    

when isMainModule:
    import os

    let root = initTui()
    var i = 0
    while true:
        if kbhit():
            let (modifier, ch) = getkey()
            case ch
            of A..Z:
                if ch == Q and Shift in modifier:
                    break
                root.write "f"
            else:
                discard
            display()
        inc i