package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"sync"
	"unsafe"

	"duanjuapp/native/core"
)

// nativeAllocations 登记本库交给调用方的每一块 C 堆内存。
// HgFree 只释放登记过的指针：重复释放、把输入指针误传进来都变成安全的空操作。
var nativeAllocations sync.Map

//export HgRequest
func HgRequest(input *C.char) *C.char {
	var output *C.char
	if input == nil {
		output = C.CString(`{"ok":false,"error":"请求为空"}`)
	} else {
		output = C.CString(core.NativeRequest(C.GoString(input)))
	}
	nativeAllocations.Store(uintptr(unsafe.Pointer(output)), struct{}{})
	return output
}

//export HgFree
func HgFree(value *C.char) {
	if value == nil {
		return
	}
	key := uintptr(unsafe.Pointer(value))
	if _, ok := nativeAllocations.LoadAndDelete(key); !ok {
		return
	}
	C.free(unsafe.Pointer(value))
}

func main() {}
