#define _UNICODE
#define UNICODE
#include <windows.h>
#include <stdio.h>

BOOL WINAPI DllMain(
    HINSTANCE hinstDLL, // handle to DLL module
    DWORD fdwReason,    // reason for calling function
    LPVOID lpvReserved) // reserved
{
    // Perform actions based on the reason for calling.
    switch (fdwReason)
    {
    case DLL_PROCESS_ATTACH:
        // Initialize once for each new process.
        // Return FALSE to fail DLL load.
        break;

    case DLL_THREAD_ATTACH:
        // Do thread-specific initialization.
        break;

    case DLL_THREAD_DETACH:
        // Do thread-specific cleanup.
        break;

    case DLL_PROCESS_DETACH:

        if (lpvReserved != NULL)
        {
            break; // do not do cleanup if process termination scenario
        }

        // Perform any necessary cleanup.
        break;
    }
    return TRUE; // Successful DLL_PROCESS_ATTACH.
}

// Export the function
__declspec(dllexport) void VfpAddRule(
    const wchar_t *name,
    const wchar_t *portid,
    const wchar_t *startip,
    const wchar_t *stopip,
    const wchar_t *priority,
    const wchar_t *gateway)
{
    // Dump the parameters
    wprintf(L"Name: %ls\n", name);
    wprintf(L"Portid: %ls\n", portid);
    wprintf(L"StartIp: %ls\n", startip);
    wprintf(L"StopIp: %ls\n", stopip);
    wprintf(L"Priority: %ls\n", priority);
    wprintf(L"Gateway: %ls\n", gateway);
}
