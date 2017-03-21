/*
 * This file is part of the C standard library for the Supercard DSTwo.
 *
 * Copyright 2017 Nebuleon Fumika <nebuleon.fumika@gmail.com>
 *
 * It is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * It is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with it.  If not, see <http://www.gnu.org/licenses/>.
*/

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

#include "../libfat/source/fatfile.h"

int open(const char* file, int flags, mode_t mode)
{
	FILE_STRUCT* handle = malloc(sizeof(FILE_STRUCT));

	if (handle == NULL) {
		errno = EMFILE; /* Too many open files (exhausted memory) */
		return -1;
	}

	if (_FAT_open(handle, file, flags, mode) == -1) {
		goto error;
	}

	return fileno(handle);

error:
	free(handle);
	return -1;
}