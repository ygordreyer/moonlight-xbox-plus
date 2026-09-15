@echo off
setlocal EnableExtensions

set "VCPKG_INSTALLED_DIR_ARG="
if not "%VCPKG_INSTALLED_DIR%"=="" (
  for %%I in ("%VCPKG_INSTALLED_DIR%") do set "VCPKG_INSTALLED_DIR=%%~fI"
  set "VCPKG_INSTALLED_DIR_ARG=-DVCPKG_INSTALLED_DIR="%VCPKG_INSTALLED_DIR%""
)

pushd third_party\moonlight-common-c || exit /b 1
cmake -B build -S . -DCMAKE_TOOLCHAIN_FILE=..\..\vcpkg\scripts\buildsystems\vcpkg.cmake -DVCPKG_TARGET_TRIPLET=x64-uwp -G "Visual Studio 17 2022" -DCMAKE_SYSTEM_NAME=WindowsStore -DCMAKE_SYSTEM_VERSION="10.0" -DTARGET_UWP=ON -DVCPKG_MANIFEST_MODE=on -DVCPKG_MANIFEST_DIR=../.. -DBUILD_SHARED_LIBS=off %VCPKG_INSTALLED_DIR_ARG%
if errorlevel 1 exit /b %errorlevel%
popd

pushd libgamestream || exit /b 1
cmake -B build -S . -DCMAKE_TOOLCHAIN_FILE=..\vcpkg\scripts\buildsystems\vcpkg.cmake -DVCPKG_TARGET_TRIPLET=x64-uwp -G "Visual Studio 17 2022" -DCMAKE_SYSTEM_NAME=WindowsStore -DCMAKE_SYSTEM_VERSION="10.0" -DTARGET_UWP=ON -DVCPKG_MANIFEST_MODE=on -DBUILD_SHARED_LIBS=off -DVCPKG_MANIFEST_DIR=.. %VCPKG_INSTALLED_DIR_ARG%
if errorlevel 1 exit /b %errorlevel%
popd
