/*
 * NppExport plugin for Notepad++ macOS
 *
 * Ported from chcg/NPP_ExportPlugin (unofficial mirror of the classic
 * NppExport plugin from sourceforge.net/projects/npp-plugins).
 * Upstream: https://github.com/chcg/NPP_ExportPlugin
 *
 * Features:
 *   - Export to RTF file (with syntax highlighting)
 *   - Export to HTML file (with syntax highlighting)
 *   - Copy RTF to clipboard
 *   - Copy HTML to clipboard
 *   - Copy all formats to clipboard (RTF + HTML + plain text)
 *
 * Scintilla styled text is read via SCI_GETSTYLEDTEXTFULL and converted to
 * RTF/HTML preserving fonts, colors, bold/italic/underline per style.
 *
 * License: GPL (as per Notepad++ plugin convention).
 */

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <cstring>
#include <cstdio>
#include <string>
#include <vector>

// ── Plugin state ────────────────────────────────────────────────────────

static const char *PLUGIN_NAME = "NppExport";
static const int NB_FUNC = 5;
static FuncItem funcItem[NB_FUNC];
static NppData nppData;

// ── Style data structures ───────────────────────────────────────────────

#define NRSTYLES (STYLE_MAX + 1)

struct StyleData {
    // 128 easily covers any macOS font name (longest real-world ones are
    // ~60 chars). SCI_STYLEGETFONT does not bounds-check.
    char fontString[128];
    int fontIndex;
    int size;
    int bold;
    int italic;
    int underlined;
    int fgColor;
    int bgColor;
    int fgClrIndex;
    int bgClrIndex;
    bool eolExtend;
};

struct ScintillaData {
    int nrChars;
    int tabSize;
    bool usedStyles[NRSTYLES];
    StyleData styles[NRSTYLES];
    std::vector<char> dataBuffer;
    int nrUsedStyles;
    int nrStyleSwitches;
    int totalFontStringLength;
    int currentCodePage;
};

static ScintillaData sdata;

// ── Forward declarations ────────────────────────────────────────────────

static void doExportRTF();
static void doExportHTML();
static void doClipboardRTF();
static void doClipboardHTML();
static void doClipboardAll();

// ── Helpers ─────────────────────────────────────────────────────────────

static NppHandle getCurScintilla()
{
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    if (which == -1)
        return 0;
    return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

static intptr_t sci(NppHandle h, uint32_t msg, uintptr_t w = 0, intptr_t l = 0)
{
    return nppData._sendMessage(h, msg, w, l);
}

// ── Fill Scintilla data ─────────────────────────────────────────────────

static void fillScintillaData(int start, int end)
{
    NppHandle h = getCurScintilla();
    if (!h) return;

    bool doColourise = true;

    if (end == 0 && start == 0) {
        int selStart = (int)sci(h, SCI_GETSELECTIONSTART);
        int selEnd = (int)sci(h, SCI_GETSELECTIONEND);
        if (selStart != selEnd) {
            start = selStart;
            end = selEnd;
            doColourise = false;
        } else {
            end = -1;
        }
    }

    if (end == -1) {
        end = (int)sci(h, SCI_GETTEXTLENGTH);
    }

    int len = end - start;
    int tabSize = (int)sci(h, SCI_GETTABWIDTH);
    int codePage = (int)sci(h, SCI_GETCODEPAGE);

    sdata.nrChars = len;
    sdata.tabSize = tabSize;
    sdata.currentCodePage = codePage;

    sdata.dataBuffer.resize((size_t)len * 2 + 2);

    Sci_TextRangeFull tr{};
    tr.lpstrText = sdata.dataBuffer.data();
    tr.chrg.cpMin = start;
    tr.chrg.cpMax = end;

    if (doColourise)
        sci(h, SCI_COLOURISE, (uintptr_t)start, (intptr_t)end);
    sci(h, SCI_GETSTYLEDTEXTFULL, 0, (intptr_t)&tr);

    // Analyze styles
    sdata.nrStyleSwitches = 0;
    sdata.nrUsedStyles = 1; // Default always
    sdata.totalFontStringLength = 0;

    for (int i = 0; i < NRSTYLES; i++)
        sdata.usedStyles[i] = false;

    sdata.usedStyles[STYLE_DEFAULT] = true;
    sci(h, SCI_STYLEGETFONT, STYLE_DEFAULT, (intptr_t)sdata.styles[STYLE_DEFAULT].fontString);
    sdata.totalFontStringLength += (int)strlen(sdata.styles[STYLE_DEFAULT].fontString);
    sdata.styles[STYLE_DEFAULT].size       = (int)sci(h, SCI_STYLEGETSIZE, STYLE_DEFAULT);
    sdata.styles[STYLE_DEFAULT].bold       = (int)sci(h, SCI_STYLEGETBOLD, STYLE_DEFAULT);
    sdata.styles[STYLE_DEFAULT].italic     = (int)sci(h, SCI_STYLEGETITALIC, STYLE_DEFAULT);
    sdata.styles[STYLE_DEFAULT].underlined = (int)sci(h, SCI_STYLEGETUNDERLINE, STYLE_DEFAULT);
    sdata.styles[STYLE_DEFAULT].fgColor    = (int)sci(h, SCI_STYLEGETFORE, STYLE_DEFAULT);
    sdata.styles[STYLE_DEFAULT].bgColor    = (int)sci(h, SCI_STYLEGETBACK, STYLE_DEFAULT);
    sdata.styles[STYLE_DEFAULT].eolExtend  = sci(h, SCI_STYLEGETEOLFILLED, STYLE_DEFAULT) != 0;

    int prevStyle = -1;
    char *buffer = sdata.dataBuffer.data();

    for (int i = 0; i < len; i++) {
        int currentStyle = (unsigned char)buffer[i * 2 + 1];
        if (currentStyle != prevStyle) {
            prevStyle = currentStyle;
            sdata.nrStyleSwitches++;
        }
        if (currentStyle >= 0 && currentStyle < NRSTYLES && !sdata.usedStyles[currentStyle]) {
            sdata.nrUsedStyles++;
            sci(h, SCI_STYLEGETFONT, (uintptr_t)currentStyle, (intptr_t)sdata.styles[currentStyle].fontString);
            sdata.totalFontStringLength += (int)strlen(sdata.styles[currentStyle].fontString);
            sdata.styles[currentStyle].size       = (int)sci(h, SCI_STYLEGETSIZE, (uintptr_t)currentStyle);
            sdata.styles[currentStyle].bold       = (int)sci(h, SCI_STYLEGETBOLD, (uintptr_t)currentStyle);
            sdata.styles[currentStyle].italic     = (int)sci(h, SCI_STYLEGETITALIC, (uintptr_t)currentStyle);
            sdata.styles[currentStyle].underlined = (int)sci(h, SCI_STYLEGETUNDERLINE, (uintptr_t)currentStyle);
            sdata.styles[currentStyle].fgColor    = (int)sci(h, SCI_STYLEGETFORE, (uintptr_t)currentStyle);
            sdata.styles[currentStyle].bgColor    = (int)sci(h, SCI_STYLEGETBACK, (uintptr_t)currentStyle);
            sdata.styles[currentStyle].eolExtend  = sci(h, SCI_STYLEGETEOLFILLED, (uintptr_t)currentStyle) != 0;
            sdata.usedStyles[currentStyle] = true;
        }
    }
}

// ── Generate HTML ───────────────────────────────────────────────────────

static std::string generateHTML()
{
    std::string out;
    char buf[512];
    char *buffer = sdata.dataBuffer.data();
    StyleData *defaultStyle = &sdata.styles[STYLE_DEFAULT];

    // DOCTYPE + head
    out += "<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/1999/REC-html401-19991224/strict.dtd\">\n";
    out += "<html>\n<head>\n";
    out += "<META http-equiv=Content-Type content=\"text/html; charset=UTF-8\">\n";
    out += "<title>Exported from Notepad++</title>\n";
    out += "<style type=\"text/css\">\n";

    // Default span style
    snprintf(buf, sizeof(buf), "span {\n\tfont-family: '%s';\n\tfont-size: %dpt;\n", defaultStyle->fontString, defaultStyle->size);
    out += buf;
    if (defaultStyle->bold) out += "\tfont-weight: bold;\n";
    if (defaultStyle->italic) out += "\tfont-style: italic;\n";
    snprintf(buf, sizeof(buf), "\tcolor: #%02X%02X%02X;\n", (defaultStyle->fgColor)&0xFF, (defaultStyle->fgColor>>8)&0xFF, (defaultStyle->fgColor>>16)&0xFF);
    out += buf;
    out += "}\n";

    // Per-style classes
    for (int i = 0; i < NRSTYLES; i++) {
        if (i == STYLE_DEFAULT) continue;
        if (!sdata.usedStyles[i]) continue;
        StyleData *s = &sdata.styles[i];
        snprintf(buf, sizeof(buf), ".sc%d {\n", i);
        out += buf;
        if (strcmp(s->fontString, defaultStyle->fontString))
            { snprintf(buf, sizeof(buf), "\tfont-family: '%s';\n", s->fontString); out += buf; }
        if (s->size != defaultStyle->size)
            { snprintf(buf, sizeof(buf), "\tfont-size: %dpt;\n", s->size); out += buf; }
        if (s->bold != defaultStyle->bold)
            out += s->bold ? "\tfont-weight: bold;\n" : "\tfont-weight: normal;\n";
        if (s->italic != defaultStyle->italic)
            out += s->italic ? "\tfont-style: italic;\n" : "\tfont-style: normal;\n";
        if (s->underlined)
            out += "\ttext-decoration: underline;\n";
        if (s->fgColor != defaultStyle->fgColor)
            { snprintf(buf, sizeof(buf), "\tcolor: #%02X%02X%02X;\n", (s->fgColor)&0xFF, (s->fgColor>>8)&0xFF, (s->fgColor>>16)&0xFF); out += buf; }
        if (s->bgColor != defaultStyle->bgColor)
            { snprintf(buf, sizeof(buf), "\tbackground: #%02X%02X%02X;\n", (s->bgColor)&0xFF, (s->bgColor>>8)&0xFF, (s->bgColor>>16)&0xFF); out += buf; }
        out += "}\n";
    }

    out += "</style>\n</head>\n<body>\n";

    // Content div
    snprintf(buf, sizeof(buf),
        "<div style=\"float: left; white-space: pre; line-height: 1; background: #%02X%02X%02X;\">",
        (defaultStyle->bgColor)&0xFF, (defaultStyle->bgColor>>8)&0xFF, (defaultStyle->bgColor>>16)&0xFF);
    out += buf;

    // Tab expansion buffer
    std::string tabBuf(sdata.tabSize, ' ');

    int lastStyle = -1;
    bool openSpan = false;
    int nrCharsSinceLinebreak = -1;

    for (int i = 0; i < sdata.nrChars; i++) {
        if ((unsigned char)buffer[i*2+1] != lastStyle) {
            if (openSpan) out += "</span>";
            lastStyle = (unsigned char)buffer[i*2+1];
            snprintf(buf, sizeof(buf), "<span class=\"sc%d\">", lastStyle);
            out += buf;
            openSpan = true;
        }

        unsigned char c = (unsigned char)buffer[i*2];
        nrCharsSinceLinebreak++;
        switch (c) {
            case '\r':
                if (i + 1 < sdata.nrChars && buffer[(i+1)*2] == '\n') break;
                // fall through
            case '\n':
                out += "\n";
                nrCharsSinceLinebreak = -1;
                break;
            case '<': out += "&lt;"; break;
            case '>': out += "&gt;"; break;
            case '&': out += "&amp;"; break;
            case '\t': {
                int skip = nrCharsSinceLinebreak % sdata.tabSize;
                out += tabBuf.substr(skip);
                nrCharsSinceLinebreak += sdata.tabSize - skip - 1;
                break;
            }
            default:
                if (c >= 0x20) out += (char)c;
                break;
        }
    }

    if (openSpan) out += "</span>";
    out += "</div>\n</body>\n</html>\n";
    return out;
}

// ── Generate RTF ────────────────────────────────────────────────────────

static std::string generateRTF()
{
    std::string out;
    char buf[512];
    char *buffer = sdata.dataBuffer.data();
    bool isUnicode = (sdata.currentCodePage == SC_CP_UTF8);

    int tabTwips = sdata.tabSize * 120; // approximate twips per space

    snprintf(buf, sizeof(buf), "{\\rtf1\\ansi\\deff0\\deftab%u\n\n", (unsigned)tabTwips);
    out += buf;

    // Font table
    out += "{\\fonttbl\n";
    int currentFontIndex = 0;
    snprintf(buf, sizeof(buf), "{\\f%03d %s;}\n", currentFontIndex, sdata.styles[STYLE_DEFAULT].fontString);
    out += buf;
    sdata.styles[STYLE_DEFAULT].fontIndex = 0;
    currentFontIndex++;

    for (int i = 0; i < NRSTYLES; i++) {
        if (i == STYLE_DEFAULT) continue;
        if (!sdata.usedStyles[i]) continue;
        StyleData *s = &sdata.styles[i];
        snprintf(buf, sizeof(buf), "{\\f%03d %s;}\n", currentFontIndex, s->fontString);
        out += buf;
        if (!strcmp(s->fontString, sdata.styles[STYLE_DEFAULT].fontString))
            s->fontIndex = sdata.styles[STYLE_DEFAULT].fontIndex;
        else
            s->fontIndex = currentFontIndex;
        currentFontIndex++;
    }
    out += "}\n\n";

    // Color table
    out += "{\\colortbl\n";
    int currentColorIndex = 0;
    for (int i = 0; i < NRSTYLES; i++) {
        if (!sdata.usedStyles[i]) continue;
        StyleData *s = &sdata.styles[i];
        snprintf(buf, sizeof(buf), "\\red%03d\\green%03d\\blue%03d;\n",
            (s->fgColor)&0xFF, (s->fgColor>>8)&0xFF, (s->fgColor>>16)&0xFF);
        out += buf;
        s->fgClrIndex = currentColorIndex++;

        snprintf(buf, sizeof(buf), "\\red%03d\\green%03d\\blue%03d;\n",
            (s->bgColor)&0xFF, (s->bgColor>>8)&0xFF, (s->bgColor>>16)&0xFF);
        out += buf;
        s->bgClrIndex = currentColorIndex++;
    }
    out += "}\n\n";

    // Default style
    snprintf(buf, sizeof(buf), "\\f%d\\fs%d\\cb%d\\cf%d ",
        sdata.styles[STYLE_DEFAULT].fontIndex,
        sdata.styles[STYLE_DEFAULT].size * 2,
        sdata.styles[STYLE_DEFAULT].bgClrIndex,
        sdata.styles[STYLE_DEFAULT].fgClrIndex);
    out += buf;

    // Content
    int lastStyle = -1;
    int prevStyle = STYLE_DEFAULT;
    StyleData *styles = sdata.styles;

    for (int i = 0; i < sdata.nrChars; i++) {
        unsigned char currentChar = (unsigned char)buffer[i*2];
        int bufferStyle = (unsigned char)buffer[i*2+1];

        if (lastStyle != bufferStyle) {
            if (lastStyle != -1) prevStyle = lastStyle;
            lastStyle = bufferStyle;

            if (styles[lastStyle].fontIndex != styles[prevStyle].fontIndex)
                { snprintf(buf, sizeof(buf), "\\f%d", styles[lastStyle].fontIndex); out += buf; }
            if (styles[lastStyle].size != styles[prevStyle].size)
                { snprintf(buf, sizeof(buf), "\\fs%d", styles[lastStyle].size * 2); out += buf; }
            if (styles[lastStyle].bgClrIndex != styles[prevStyle].bgClrIndex)
                { snprintf(buf, sizeof(buf), "\\highlight%d", styles[lastStyle].bgClrIndex); out += buf; }
            if (styles[lastStyle].fgClrIndex != styles[prevStyle].fgClrIndex)
                { snprintf(buf, sizeof(buf), "\\cf%d", styles[lastStyle].fgClrIndex); out += buf; }
            if (styles[lastStyle].bold != styles[prevStyle].bold)
                out += styles[lastStyle].bold ? "\\b" : "\\b0";
            if (styles[lastStyle].italic != styles[prevStyle].italic)
                out += styles[lastStyle].italic ? "\\i" : "\\i0";
            if (styles[lastStyle].underlined != styles[prevStyle].underlined)
                out += styles[lastStyle].underlined ? "\\ul" : "\\ul0";
            out += " ";
        }

        switch (currentChar) {
            case '{': out += "\\{"; break;
            case '}': out += "\\}"; break;
            case '\\': out += "\\\\"; break;
            case '\t': out += "\\tab "; break;
            case '\r':
                if (i + 1 < sdata.nrChars && buffer[(i+1)*2] == '\n') break;
                // fall through
            case '\n': out += "\\par\n"; break;
            default:
                if (currentChar < 0x20) break;
                if (currentChar > 0x7F && isUnicode) {
                    // Decode a full UTF-8 sequence (1..4 bytes). Emit RTF
                    // \uN? escape. For supplementary-plane code points
                    // (U+10000..U+10FFFF) emit a UTF-16 surrogate pair,
                    // since \u takes a signed 16-bit value.
                    unsigned int cp = 0;
                    int extraBytes = 0;
                    if ((currentChar & 0xE0) == 0xC0) {           // 110xxxxx
                        cp = currentChar & 0x1F;
                        extraBytes = 1;
                    } else if ((currentChar & 0xF0) == 0xE0) {    // 1110xxxx
                        cp = currentChar & 0x0F;
                        extraBytes = 2;
                    } else if ((currentChar & 0xF8) == 0xF0) {    // 11110xxx
                        cp = currentChar & 0x07;
                        extraBytes = 3;
                    } else {
                        // 10xxxxxx continuation byte in isolation, or
                        // 11111xxx invalid lead — emit replacement char.
                        snprintf(buf, sizeof(buf), "\\u%d?", (short)0xFFFD);
                        out += buf;
                        break;
                    }

                    bool valid = true;
                    for (int b = 0; b < extraBytes; b++) {
                        if (i + 1 >= sdata.nrChars) { valid = false; break; }
                        i++;
                        unsigned char cont = (unsigned char)buffer[i*2];
                        if ((cont & 0xC0) != 0x80) { valid = false; break; }
                        cp = (cp << 6) | (cont & 0x3F);
                    }

                    if (!valid || cp > 0x10FFFF) {
                        snprintf(buf, sizeof(buf), "\\u%d?", (short)0xFFFD);
                        out += buf;
                    } else if (cp <= 0xFFFF) {
                        snprintf(buf, sizeof(buf), "\\u%d?", (short)cp);
                        out += buf;
                    } else {
                        unsigned int scaled = cp - 0x10000;
                        unsigned int hi = 0xD800 + (scaled >> 10);
                        unsigned int lo = 0xDC00 + (scaled & 0x3FF);
                        snprintf(buf, sizeof(buf), "\\u%d?\\u%d?",
                                 (short)hi, (short)lo);
                        out += buf;
                    }
                } else {
                    out += (char)currentChar;
                }
                break;
        }
    }

    out += "}\n";
    return out;
}

// ── Save file dialog (NSSavePanel) ──────────────────────────────────────

// Returns the full POSIX path the user picked, or nil on cancel.
// contentType constrains the save panel to a specific UTI (e.g. UTTypeRTF)
// and causes Finder to append the extension automatically if the user
// types a name without one. suggestedName should already have the right
// extension; the panel will re-use it.
//
// NOTE: intentionally does NOT use its own @autoreleasepool. The returned
// NSString from `[[panel URL] path]` is autoreleased; an inner pool would
// drain that autorelease before the return delivered the pointer to the
// caller, leaving a dangling pointer (SIGSEGV inside -writeToFile). The
// caller must already be inside an @autoreleasepool so the returned string
// has somewhere to live. This plugin compiles without ARC so we can't
// lean on automatic retains.
static NSString *showSavePanel(NSString *suggestedName, UTType *contentType)
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = suggestedName;
    if (contentType) {
        panel.allowedContentTypes = @[contentType];
    }
    panel.allowsOtherFileTypes = YES;
    if ([panel runModal] == NSModalResponseOK) {
        return [[panel URL] path];
    }
    return nil;
}

// Build a suggested filename like "foo.rtf" from the current Notepad++
// document name "foo.cpp", replacing (not appending to) the extension.
static NSString *suggestedNameWithExtension(NSString *ext)
{
    char nameBuf[1024] = {};
    nppData._sendMessage(nppData._nppHandle, NPPM_GETFILENAME, 1023, (intptr_t)nameBuf);
    NSString *base = [[NSString stringWithUTF8String:nameBuf] stringByDeletingPathExtension];
    if (base.length == 0) base = @"untitled";
    return [base stringByAppendingPathExtension:ext];
}

// ── Export to file commands ─────────────────────────────────────────────

static void doExportRTF()
{
    @autoreleasepool {
        fillScintillaData(0, -1);
        NSString *suggestedName = suggestedNameWithExtension(@"rtf");
        NSString *path = showSavePanel(suggestedName, UTTypeRTF);
        if (!path) return;

        std::string rtf = generateRTF();
        NSData *data = [NSData dataWithBytes:rtf.c_str() length:rtf.size()];
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
    }
}

static void doExportHTML()
{
    @autoreleasepool {
        fillScintillaData(0, -1);
        NSString *suggestedName = suggestedNameWithExtension(@"html");
        NSString *path = showSavePanel(suggestedName, UTTypeHTML);
        if (!path) return;

        std::string html = generateHTML();
        NSData *data = [NSData dataWithBytes:html.c_str() length:html.size()];
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
    }
}

// ── Copy to clipboard commands ──────────────────────────────────────────

// Read the plain-text version of what fillScintillaData just grabbed:
// if the user has a non-empty selection use it, otherwise use the full
// buffer. Shared by doClipboardAll() so RTF / HTML / plain-text all
// reflect the same range.
static std::string readPlainTextForClipboard()
{
    NppHandle h = getCurScintilla();
    if (!h) return {};
    int selStart = (int)sci(h, SCI_GETSELECTIONSTART);
    int selEnd   = (int)sci(h, SCI_GETSELECTIONEND);
    int len;
    if (selStart != selEnd) {
        len = selEnd - selStart;
    } else {
        len = (int)sci(h, SCI_GETTEXTLENGTH);
    }
    if (len <= 0) return {};
    std::vector<char> textBuf(len + 1);
    if (selStart != selEnd) {
        sci(h, SCI_GETSELTEXT, 0, (intptr_t)textBuf.data());
    } else {
        sci(h, SCI_GETTEXT, (uintptr_t)(len + 1), (intptr_t)textBuf.data());
    }
    return std::string(textBuf.data(), len);
}

// All three clipboard commands follow the same pattern: put the rich
// flavor (public.rtf / public.html) for rich paste targets, and put the
// source markup as the plain-text fallback so pasting into plain-text
// targets like a Notepad++ tab shows the generated markup rather than
// the original selection. doClipboardAll concatenates HTML + RTF + plain
// text with section headers in its plain-text fallback.

static void doClipboardRTF()
{
    @autoreleasepool {
        fillScintillaData(0, 0);
        std::string rtf = generateRTF();

        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb declareTypes:@[NSPasteboardTypeRTF, NSPasteboardTypeString] owner:nil];
        NSData *rtfData = [NSData dataWithBytes:rtf.c_str() length:rtf.size()];
        [pb setData:rtfData forType:NSPasteboardTypeRTF];

        NSString *rtfSource = [NSString stringWithUTF8String:rtf.c_str()];
        if (rtfSource) {
            [pb setString:rtfSource forType:NSPasteboardTypeString];
        }
    }
}

static void doClipboardHTML()
{
    @autoreleasepool {
        fillScintillaData(0, 0);
        std::string html = generateHTML();

        NSString *htmlNS = [NSString stringWithUTF8String:html.c_str()];
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb declareTypes:@[NSPasteboardTypeHTML, NSPasteboardTypeString] owner:nil];
        [pb setString:htmlNS forType:NSPasteboardTypeHTML];

        if (htmlNS) {
            [pb setString:htmlNS forType:NSPasteboardTypeString];
        }
    }
}

static void doClipboardAll()
{
    @autoreleasepool {
        fillScintillaData(0, 0);

        std::string rtf   = generateRTF();
        std::string html  = generateHTML();
        std::string plain = readPlainTextForClipboard();

        std::string combined;
        combined.reserve(html.size() + rtf.size() + plain.size() + 256);
        combined += "===== HTML =====\n";
        combined += html;
        if (!html.empty() && html.back() != '\n') combined += "\n";
        combined += "\n===== RTF =====\n";
        combined += rtf;
        if (!rtf.empty() && rtf.back() != '\n') combined += "\n";
        combined += "\n===== Plain Text =====\n";
        combined += plain;
        if (!plain.empty() && plain.back() != '\n') combined += "\n";

        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb declareTypes:@[NSPasteboardTypeRTF,
                           NSPasteboardTypeHTML,
                           NSPasteboardTypeString] owner:nil];

        NSData *rtfData = [NSData dataWithBytes:rtf.c_str() length:rtf.size()];
        [pb setData:rtfData forType:NSPasteboardTypeRTF];
        [pb setString:[NSString stringWithUTF8String:html.c_str()]
              forType:NSPasteboardTypeHTML];
        [pb setString:[NSString stringWithUTF8String:combined.c_str()]
              forType:NSPasteboardTypeString];
    }
}

// ── Plugin exports ──────────────────────────────────────────────────────

extern "C" NPP_EXPORT void setInfo(NppData data)
{
    nppData = data;

    strlcpy(funcItem[0]._itemName, "Export to RTF", NPP_MENU_ITEM_SIZE);
    funcItem[0]._pFunc = doExportRTF;
    funcItem[0]._init2Check = false;
    funcItem[0]._pShKey = nullptr;

    strlcpy(funcItem[1]._itemName, "Export to HTML", NPP_MENU_ITEM_SIZE);
    funcItem[1]._pFunc = doExportHTML;
    funcItem[1]._init2Check = false;
    funcItem[1]._pShKey = nullptr;

    strlcpy(funcItem[2]._itemName, "Copy RTF to clipboard", NPP_MENU_ITEM_SIZE);
    funcItem[2]._pFunc = doClipboardRTF;
    funcItem[2]._init2Check = false;
    funcItem[2]._pShKey = nullptr;

    strlcpy(funcItem[3]._itemName, "Copy HTML to clipboard", NPP_MENU_ITEM_SIZE);
    funcItem[3]._pFunc = doClipboardHTML;
    funcItem[3]._init2Check = false;
    funcItem[3]._pShKey = nullptr;

    strlcpy(funcItem[4]._itemName, "Copy all formats to clipboard", NPP_MENU_ITEM_SIZE);
    funcItem[4]._pFunc = doClipboardAll;
    funcItem[4]._init2Check = false;
    funcItem[4]._pShKey = nullptr;
}

extern "C" NPP_EXPORT const char *getName()
{
    return PLUGIN_NAME;
}

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF)
{
    *nbF = NB_FUNC;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *)
{
    // No notifications needed
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t)
{
    return 1;
}
