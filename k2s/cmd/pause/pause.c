// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

#include <windows.h>
#include <stdio.h>

BOOL WINAPI CtrlHandler(DWORD fdwCtrlType)
{
	switch (fdwCtrlType)
	{
	case CTRL_C_EVENT:
		fprintf(stderr, "Shutting down, got signal\n");
		exit(0);

	case CTRL_BREAK_EVENT:
		fprintf(stderr, "Shutting down, got signal\n");
		exit(0);

	default:
		return FALSE;
	}
}

int main(void)
{
	if (SetConsoleCtrlHandler(CtrlHandler, TRUE))
	{
		Sleep(INFINITE);
	}
	else
	{
		printf("\nERROR: Could not set control handler\n");
		return 1;
	}
	return 0;
}
