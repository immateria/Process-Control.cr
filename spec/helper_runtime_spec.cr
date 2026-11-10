require "./spec_helper"
require "../scripts/helper/runtime"

describe ProcessControl::Platform::Unix::Helper::Runtime do
  it "rejects state whose initialization may require the inactive runtime" do
    ir = <<-IR
      @state = internal global i32 0
      define i32 @main() {
        %value = load i32, ptr @state
        ret i32 %value
      }
      IR
    expect_raises(ArgumentError, /mutable global/) { ProcessControl::Platform::Unix::Helper::Runtime.verify(ir) }
  end

  it "accepts Darwin's inode-64 directory function alias" do
    ir = <<-IR
      declare ptr @"opendir$INODE64"(ptr)
      define i32 @main() {
        %directory = call ptr @"opendir$INODE64"(ptr null)
        ret i32 0
      }
      IR
    ProcessControl::Platform::Unix::Helper::Runtime.verify(ir)
  end

  it "accepts the compiler's signed minimum integer intrinsic" do
    ir = "declare i32 @llvm.smin.i32(i32, i32)\ndefine i32 @main() {\n%x = call i32 @llvm.smin.i32(i32 2, i32 3)\nret i32 %x\n}\n"
    ProcessControl::Platform::Unix::Helper::Runtime.verify(ir)
  end

  it "does not treat quoted local names or string data as global references" do
    ir = <<-IR
      @message = constant [13 x i8] c"call @Pointer"
      declare i64 @write(i32, ptr, i64)
      define i32 @main() {
        %sent = call i64 @write(i32 1, ptr @message, i64 13)
        br label %"*Pointer(UInt8)#call@Pointer(T).exit"
      "*Pointer(UInt8)#call@Pointer(T).exit":
        ret i32 0
      }
      IR
    ProcessControl::Platform::Unix::Helper::Runtime.verify(ir)
  end

  it "accepts a native entry point and an unused runtime definition" do
    ir = <<-IR
      declare i32 @fork()
      declare ptr @GC_malloc(i64)
      define i32 @main() {
        %child = call i32 @fork()
        ret i32 0
      }
      define ptr @unused() {
        %object = call ptr @GC_malloc(i64 8)
        ret ptr %object
      }
      IR
    ProcessControl::Platform::Unix::Helper::Runtime.verify(ir)
  end

  it "rejects managed allocation reached through another function" do
    ir = <<-IR
      declare ptr @GC_malloc(i64)
      define i32 @main() {
        call void @allocate()
        ret i32 0
      }
      define void @allocate() {
        %object = call ptr @GC_malloc(i64 8)
        ret void
      }
      IR
    expect_raises(ArgumentError, /GC_malloc/) { ProcessControl::Platform::Unix::Helper::Runtime.verify(ir) }
  end

  it "follows callbacks passed through constant pointer tables" do
    ir = <<-IR
      @callbacks = constant [1 x ptr] [ptr @callback]
      declare i32 @sigaction(i32, ptr, ptr)
      declare void @__crystal_raise()
      define i32 @main() {
        %result = call i32 @sigaction(i32 20, ptr @callbacks, ptr null)
        ret i32 0
      }
      define void @callback() {
        call void @__crystal_raise()
        ret void
      }
      IR
    expect_raises(ArgumentError, /__crystal_raise/) { ProcessControl::Platform::Unix::Helper::Runtime.verify(ir) }
  end

  it "rejects constructors and indirect calls even with an allowed argument" do
    constructor = "@llvm.global_ctors = appending global [0 x ptr] []\ndefine i32 @main() {\nret i32 0\n}\n"
    expect_raises(ArgumentError, /constructors/) { ProcessControl::Platform::Unix::Helper::Runtime.verify(constructor) }
    indirect = <<-IR
      declare i32 @fork()
      define i32 @main(ptr %callback) {
        call void %callback(ptr @fork)
        ret i32 0
      }
      IR
    expect_raises(ArgumentError, /indirect/) { ProcessControl::Platform::Unix::Helper::Runtime.verify(indirect) }
  end

  it "rejects an unapproved native import" do
    ir = "declare i32 @system(ptr)\ndefine i32 @main() {\n%x = call i32 @system(ptr null)\nret i32 0\n}\n"
    expect_raises(ArgumentError, /system/) { ProcessControl::Platform::Unix::Helper::Runtime.verify(ir) }
  end
end
