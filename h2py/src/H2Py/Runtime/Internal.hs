{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_HADDOCK hide #-}

{- |
The foreign side of H2Py: raw imports of the shim in @cbits/h2py.c@ and of the
CPython limited API, and the trampoline that every call from Python enters.

Every CPython function that can run Python code, block, or call back into
Haskell is imported @safe@; only @Py_IncRef@ and the exact-type leaf reads are
@unsafe@.
Nothing here is meant for users; the safe surface is "H2Py".
-}
module H2Py.Runtime.Internal (
  module H2Py.Runtime.Internal,
) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, mask, try)
import Data.Int (Int64)
import Foreign.C.String (CString)
import Foreign.C.Types (CChar (..), CDouble (..), CInt (..), CLLong (..), CSize (..), CULong (..))
import Foreign.Ptr (FunPtr, Ptr, nullPtr)

-- | An opaque CPython object; only ever handled through a pointer.
data PyObject

-- | An opaque CPython type object.
data PyTypeObject

-- | An opaque arena of the shim.
data Arena

-- | An opaque buffer view of the shim.
data BufView

-- | An opaque class cell of the shim: payload, lend state, export count.
data Cell

-- | @Py_ssize_t@.
type PySSize = Int64

{- | The calling convention of every function and method H2Py registers:
@METH_FASTCALL | METH_KEYWORDS@.
-}
type FastCall = Ptr PyObject -> Ptr (Ptr PyObject) -> PySSize -> Ptr PyObject -> IO (Ptr PyObject)

-- | @tp_new@: the type being constructed, the positional tuple, the keyword dict.
type NewFunc = Ptr PyTypeObject -> Ptr PyObject -> Ptr PyObject -> IO (Ptr PyObject)

-- | @tp_dealloc@.
type Destructor = Ptr PyObject -> IO ()

-- | @tp_repr@, @tp_str@, @tp_iter@, @tp_iternext@, @nb_negative@ and every other unary slot.
type UnaryFunc = Ptr PyObject -> IO (Ptr PyObject)

-- | @nb_add@ and the other binary slots, @mp_subscript@.
type BinaryFunc = Ptr PyObject -> Ptr PyObject -> IO (Ptr PyObject)

-- | @tp_hash@, @sq_length@, @mp_length@.
type LenFunc = Ptr PyObject -> IO PySSize

-- | @nb_bool@, @sq_contains@.
type Inquiry = Ptr PyObject -> Ptr PyObject -> IO CInt

-- | @nb_bool@ proper.
type Inquiry1 = Ptr PyObject -> IO CInt

-- | @tp_richcompare@.
type RichCmpFunc = Ptr PyObject -> Ptr PyObject -> CInt -> IO (Ptr PyObject)

-- | @mp_ass_subscript@: a @NULL@ value deletes.
type ObjObjArgProc = Ptr PyObject -> Ptr PyObject -> Ptr PyObject -> IO CInt

-- | @tp_call@ in @(args, kwargs)@ form.
type TernaryFunc = Ptr PyObject -> Ptr PyObject -> Ptr PyObject -> IO (Ptr PyObject)

-- | @bf_getbuffer@.
type GetBufferProc = Ptr PyObject -> Ptr () -> CInt -> IO CInt

-- | @bf_releasebuffer@.
type ReleaseBufferProc = Ptr PyObject -> Ptr () -> IO ()

foreign import ccall "wrapper" mkFastCall :: FastCall -> IO (FunPtr FastCall)

foreign import ccall "wrapper" mkNewFunc :: NewFunc -> IO (FunPtr NewFunc)

foreign import ccall "wrapper" mkDestructor :: Destructor -> IO (FunPtr Destructor)

foreign import ccall "wrapper" mkUnaryFunc :: UnaryFunc -> IO (FunPtr UnaryFunc)

foreign import ccall "wrapper" mkBinaryFunc :: BinaryFunc -> IO (FunPtr BinaryFunc)

foreign import ccall "wrapper" mkLenFunc :: LenFunc -> IO (FunPtr LenFunc)

foreign import ccall "wrapper" mkInquiry :: Inquiry -> IO (FunPtr Inquiry)

foreign import ccall "wrapper" mkInquiry1 :: Inquiry1 -> IO (FunPtr Inquiry1)

foreign import ccall "wrapper" mkRichCmpFunc :: RichCmpFunc -> IO (FunPtr RichCmpFunc)

foreign import ccall "wrapper" mkObjObjArgProc :: ObjObjArgProc -> IO (FunPtr ObjObjArgProc)

foreign import ccall "wrapper" mkTernaryFunc :: TernaryFunc -> IO (FunPtr TernaryFunc)

foreign import ccall "wrapper" mkGetBufferProc :: GetBufferProc -> IO (FunPtr GetBufferProc)

foreign import ccall "wrapper" mkReleaseBufferProc :: ReleaseBufferProc -> IO (FunPtr ReleaseBufferProc)

-- * The shim: attachment, arenas, pool

foreign import ccall unsafe "h2py_is_attached" c_isAttached :: IO CInt

foreign import ccall unsafe "h2py_is_finalizing" c_isFinalizing :: IO CInt

foreign import ccall unsafe "h2py_is_forked_child" c_isForkedChild :: IO CInt

foreign import ccall safe "h2py_call_begin" c_callBegin :: IO (Ptr Arena)

foreign import ccall safe "h2py_call_end" c_callEnd :: Ptr Arena -> CInt -> IO ()

foreign import ccall safe "h2py_attach_begin" c_attachBegin :: IO (Ptr Arena)

foreign import ccall safe "h2py_attach_end" c_attachEnd :: Ptr Arena -> CInt -> IO ()

foreign import ccall unsafe "h2py_scope_begin" c_scopeBegin :: IO (Ptr Arena)

foreign import ccall safe "h2py_scope_end" c_scopeEnd :: Ptr Arena -> CInt -> IO ()

foreign import ccall safe "h2py_detach_begin" c_detachBegin :: IO (Ptr ())

foreign import ccall safe "h2py_detach_end" c_detachEnd :: Ptr () -> IO CInt

foreign import ccall unsafe "h2py_arena_current" c_arenaCurrent :: IO (Ptr Arena)

foreign import ccall unsafe "h2py_arena_register" c_arenaRegister :: Ptr Arena -> Ptr PyObject -> IO ()

foreign import ccall unsafe "h2py_arena_set_ctor" c_arenaSetCtor :: Ptr Arena -> Ptr PyTypeObject -> Ptr PyTypeObject -> IO ()

foreign import ccall unsafe "h2py_arena_take_ctor_type" c_arenaTakeCtorType :: Ptr Arena -> Ptr PyTypeObject -> IO (Ptr PyTypeObject)

foreign import ccall unsafe "h2py_pool_push" c_poolPush :: Ptr PyObject -> IO ()

foreign import ccall safe "h2py_pool_drain" c_poolDrain :: IO ()

-- * The shim: cells

foreign import ccall unsafe "h2py_cell_basicsize" c_cellBasicSize :: IO PySSize

foreign import ccall unsafe "h2py_cell_of" c_cellOf :: Ptr PyObject -> Ptr PyTypeObject -> IO (Ptr Cell)

foreign import ccall unsafe "h2py_cell_payload" c_cellPayload :: Ptr Cell -> IO (Ptr ())

foreign import ccall unsafe "h2py_cell_set_payload" c_cellSetPayload :: Ptr Cell -> Ptr () -> IO ()

foreign import ccall unsafe "h2py_cell_lend" c_cellLend :: Ptr Cell -> IO Int64

foreign import ccall unsafe "h2py_cell_exports" c_cellExports :: Ptr Cell -> IO Int64

foreign import ccall unsafe "h2py_cell_claim_mut" c_cellClaimMut :: Ptr Arena -> Ptr PyObject -> Ptr PyTypeObject -> IO CInt

foreign import ccall unsafe "h2py_cell_claim_shared" c_cellClaimShared :: Ptr Arena -> Ptr PyObject -> Ptr PyTypeObject -> IO CInt

foreign import ccall unsafe "h2py_cell_copy_begin" c_cellCopyBegin :: Ptr Cell -> IO CInt

foreign import ccall unsafe "h2py_cell_copy_end" c_cellCopyEnd :: Ptr Cell -> IO ()

foreign import ccall unsafe "h2py_cell_export_begin" c_cellExportBegin :: Ptr Cell -> IO CInt

foreign import ccall unsafe "h2py_cell_export_end" c_cellExportEnd :: Ptr Cell -> IO ()

foreign import ccall safe "h2py_alloc_instance" c_allocInstance :: Ptr PyTypeObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_finish_dealloc" c_finishDealloc :: Ptr PyObject -> IO ()

-- * The shim: types, methods, argument binding

foreign import ccall safe "h2py_make_type"
  c_makeType ::
    Ptr PyObject -> CString -> CString -> PySSize -> CULong -> Ptr CInt -> Ptr (Ptr ()) -> CInt -> Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall unsafe "h2py_methoddefs_new" c_methodDefsNew :: CInt -> IO (Ptr ())

foreign import ccall unsafe "h2py_methoddef_set" c_methodDefSet :: Ptr () -> CInt -> CString -> Ptr () -> CInt -> CString -> IO ()

foreign import ccall safe "h2py_bind_args"
  c_bindArgs :: Ptr (Ptr PyObject) -> PySSize -> Ptr PyObject -> Ptr CString -> PySSize -> Ptr (Ptr PyObject) -> IO CInt

foreign import ccall safe "h2py_unpack_call" c_unpackCall :: Ptr PyObject -> Ptr PyObject -> Ptr PySSize -> Ptr (Ptr PyObject) -> IO (Ptr (Ptr PyObject))

foreign import ccall unsafe "h2py_free" c_free :: Ptr a -> IO ()

foreign import ccall unsafe "h2py_builtin_type" c_builtinType :: CInt -> IO (Ptr PyObject)

foreign import ccall unsafe "h2py_exception_type" c_exceptionType :: CInt -> IO (Ptr PyObject)

foreign import ccall unsafe "h2py_none" c_none :: IO (Ptr PyObject)

foreign import ccall unsafe "h2py_true" c_true :: IO (Ptr PyObject)

foreign import ccall unsafe "h2py_false" c_false :: IO (Ptr PyObject)

foreign import ccall unsafe "h2py_not_implemented" c_notImplemented :: IO (Ptr PyObject)

foreign import ccall safe "h2py_set_error" c_setError :: Ptr PyObject -> CString -> IO ()

foreign import ccall unsafe "h2py_err_occurred" c_errOccurred :: IO CInt

foreign import ccall safe "h2py_take_error" c_takeError :: IO (Ptr PyObject)

foreign import ccall safe "h2py_write_unraisable" c_writeUnraisable :: Ptr PyObject -> IO ()

foreign import ccall safe "h2py_check_signals" c_checkSignals :: IO CInt

-- * The shim: buffers

foreign import ccall safe "h2py_buffer_request" c_bufferRequest :: Ptr Arena -> Ptr PyObject -> CInt -> IO (Ptr BufView)

foreign import ccall unsafe "h2py_buffer_data" c_bufferData :: Ptr BufView -> IO (Ptr ())

foreign import ccall unsafe "h2py_buffer_len" c_bufferLen :: Ptr BufView -> IO PySSize

foreign import ccall unsafe "h2py_buffer_itemsize" c_bufferItemSize :: Ptr BufView -> IO PySSize

foreign import ccall unsafe "h2py_buffer_format" c_bufferFormat :: Ptr BufView -> IO CString

foreign import ccall unsafe "h2py_buffer_readonly" c_bufferReadOnly :: Ptr BufView -> IO CInt

foreign import ccall safe "h2py_buffer_release" c_bufferRelease :: Ptr BufView -> IO ()

foreign import ccall unsafe "h2py_buffer_released" c_bufferReleased :: Ptr BufView -> IO CInt

foreign import ccall unsafe "h2py_fill_buffer" c_fillBuffer :: Ptr () -> Ptr PyObject -> Ptr () -> PySSize -> PySSize -> CString -> CInt -> IO CInt

foreign import ccall unsafe "h2py_buffer_fail" c_bufferFail :: Ptr () -> IO ()

foreign import ccall unsafe "h2py_buffer_free_internal" c_bufferFreeInternal :: Ptr () -> IO ()

foreign import ccall unsafe "h2py_hash_not_implemented" c_hashNotImplemented :: IO (Ptr ())

foreign import ccall safe "h2py_hsbuffer_new" c_hsBufferNew :: Ptr () -> Ptr () -> PySSize -> PySSize -> CString -> IO (Ptr PyObject)

-- * CPython: references and errors

foreign import ccall unsafe "h2py_api_Py_IncRef" c_incref :: Ptr PyObject -> IO ()

foreign import ccall safe "h2py_api_Py_DecRef" c_decref :: Ptr PyObject -> IO ()

foreign import ccall safe "h2py_api_PyErr_SetRaisedException" c_setRaisedException :: Ptr PyObject -> IO ()

foreign import ccall safe "h2py_api_PyErr_SetObject" c_errSetObject :: Ptr PyObject -> Ptr PyObject -> IO ()

foreign import ccall safe "h2py_api_PyErr_NewException" c_errNewException :: CString -> Ptr PyObject -> Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyObject_Str" c_objectStr :: Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyObject_Repr" c_objectRepr :: Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyObject_Type" c_objectType :: Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyObject_IsInstance" c_isInstance :: Ptr PyObject -> Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyObject_IsSubclass" c_isSubclass :: Ptr PyObject -> Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyObject_IsTrue" c_isTrue :: Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyObject_GetAttr" c_getAttr :: Ptr PyObject -> Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyObject_GetAttrString" c_getAttrString :: Ptr PyObject -> CString -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyObject_SetAttrString" c_setAttrString :: Ptr PyObject -> CString -> Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyObject_HasAttrString" c_hasAttrString :: Ptr PyObject -> CString -> IO CInt

foreign import ccall safe "h2py_api_PyObject_GetItem" c_getItem :: Ptr PyObject -> Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyObject_SetItem" c_setItem :: Ptr PyObject -> Ptr PyObject -> Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyObject_DelItem" c_delItem :: Ptr PyObject -> Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyObject_Length" c_length :: Ptr PyObject -> IO PySSize

foreign import ccall safe "h2py_api_PyObject_Hash" c_hash :: Ptr PyObject -> IO PySSize

foreign import ccall safe "h2py_api_PyObject_RichCompareBool" c_richCompareBool :: Ptr PyObject -> Ptr PyObject -> CInt -> IO CInt

foreign import ccall safe "h2py_api_PyObject_RichCompare" c_richCompare :: Ptr PyObject -> Ptr PyObject -> CInt -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyObject_Vectorcall" c_vectorcall :: Ptr PyObject -> Ptr (Ptr PyObject) -> CSize -> Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyObject_Call" c_call :: Ptr PyObject -> Ptr PyObject -> Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyObject_CallNoArgs" c_callNoArgs :: Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyObject_GetIter" c_getIter :: Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyIter_Next" c_iterNext :: Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PySequence_GetItem" c_sequenceGetItem :: Ptr PyObject -> PySSize -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PySequence_Size" c_sequenceSize :: Ptr PyObject -> IO PySSize

foreign import ccall safe "h2py_api_PySequence_Check" c_sequenceCheck :: Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyMapping_Check" c_mappingCheck :: Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyMapping_Items" c_mappingItems :: Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyDict_New" c_dictNew :: IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyDict_SetItem" c_dictSetItem :: Ptr PyObject -> Ptr PyObject -> Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyList_New" c_listNew :: PySSize -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyList_SetItem" c_listSetItem :: Ptr PyObject -> PySSize -> Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyList_Append" c_listAppend :: Ptr PyObject -> Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyTuple_New" c_tupleNew :: PySSize -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyTuple_SetItem" c_tupleSetItem :: Ptr PyObject -> PySSize -> Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyTuple_Size" c_tupleSize :: Ptr PyObject -> IO PySSize

foreign import ccall safe "h2py_api_PyTuple_GetItem" c_tupleGetItem :: Ptr PyObject -> PySSize -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PySet_New" c_setNew :: Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PySet_Add" c_setAdd :: Ptr PyObject -> Ptr PyObject -> IO CInt

-- * CPython: scalars

foreign import ccall safe "h2py_api_PyLong_FromLongLong" c_longFromLongLong :: CLLong -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyLong_AsLongLong" c_longAsLongLong :: Ptr PyObject -> IO CLLong

foreign import ccall safe "h2py_api_PyLong_FromString" c_longFromString :: CString -> Ptr CString -> CInt -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyNumber_ToBase" c_numberToBase :: Ptr PyObject -> CInt -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyNumber_Long" c_numberLong :: Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyNumber_Index" c_numberIndex :: Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyFloat_FromDouble" c_floatFromDouble :: CDouble -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyFloat_AsDouble" c_floatAsDouble :: Ptr PyObject -> IO CDouble

foreign import ccall safe "h2py_api_PyBool_FromLong" c_boolFromLong :: CLLong -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyUnicode_FromStringAndSize" c_unicodeFromStringAndSize :: Ptr CChar -> PySSize -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyUnicode_AsUTF8AndSize" c_unicodeAsUTF8AndSize :: Ptr PyObject -> Ptr PySSize -> IO (Ptr CChar)

foreign import ccall safe "h2py_api_PyBytes_FromStringAndSize" c_bytesFromStringAndSize :: Ptr CChar -> PySSize -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyBytes_AsStringAndSize" c_bytesAsStringAndSize :: Ptr PyObject -> Ptr (Ptr CChar) -> Ptr PySSize -> IO CInt

-- * CPython: modules

foreign import ccall safe "h2py_api_PyModule_AddFunctions" c_moduleAddFunctions :: Ptr PyObject -> Ptr () -> IO CInt

foreign import ccall safe "h2py_api_PyModule_AddObjectRef" c_moduleAddObjectRef :: Ptr PyObject -> CString -> Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyModule_New" c_moduleNew :: CString -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyModule_GetNameObject" c_moduleGetNameObject :: Ptr PyObject -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyImport_ImportModule" c_importModule :: CString -> IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyImport_GetModuleDict" c_importGetModuleDict :: IO (Ptr PyObject)

foreign import ccall safe "h2py_api_PyDict_SetItemString" c_dictSetItemString :: Ptr PyObject -> CString -> Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyType_GetSlot" c_typeGetSlot :: Ptr PyTypeObject -> CInt -> IO (Ptr ())

foreign import ccall safe "h2py_api_PyType_IsSubtype" c_typeIsSubtype :: Ptr PyTypeObject -> Ptr PyTypeObject -> IO CInt

foreign import ccall safe "h2py_api_PyCallable_Check" c_callableCheck :: Ptr PyObject -> IO CInt

foreign import ccall safe "h2py_api_PyMemoryView_FromObject" c_memoryViewFromObject :: Ptr PyObject -> IO (Ptr PyObject)

-- * Haskell-side helpers over the raw imports

-- | Whether the current thread holds the interpreter for H2Py.
isAttached :: IO Bool
isAttached = (/= 0) <$> c_isAttached

-- | The innermost arena of the current thread.
currentArena :: IO (Ptr Arena)
currentArena = c_arenaCurrent

{- | Bracket a computation between @h2py_call_begin@ and @h2py_call_end@ under
'mask', poisoning the arena's mutable holds on an exceptional exit.
The first argument is the value returned to Python when the call fails after
raising: @NULL@ for an object slot, @-1@ for a status or length slot.
No Haskell exception ever leaves.
-}
withCallArena :: x -> (Ptr Arena -> IO x) -> (SomeException -> IO ()) -> IO x
withCallArena failed body onException = mask \restore -> do
  arena <- c_callBegin
  if arena == nullPtr
    then pure failed
    else do
      r <- try (restore (body arena))
      case r of
        Right p -> do
          c_callEnd arena 0
          pure p
        Left e -> do
          attached <- isAttached
          if attached
            then do
              r' <- try (onException e)
              case r' of
                Right () -> pure ()
                Left (_ :: SomeException) -> pure ()
              c_callEnd arena 1
              pure failed
            else do
              -- The thread lost the interpreter during finalisation.
              -- Nothing may touch CPython again, and returning into Python is
              -- not possible either, so the thread stays here, as CPython's
              -- own documented behaviour for a daemon thread at exit is.
              c_callEnd arena 1
              hangForever

-- | Park the current thread for good, as CPython does with a daemon thread at exit.
hangForever :: IO a
hangForever = do
  threadDelay maxBound
  hangForever
