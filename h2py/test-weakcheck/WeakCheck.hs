{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoOverloadedStrings #-}

-- | See the stanza comment in h2py.cabal.
module Main (main) where

import Control.Monad (filterM, forM, forM_, unless, when)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import Data.Maybe (mapMaybe)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.Info (os)
import System.Process (readProcess)
import Prelude

main :: IO ()
main = do
  ok1 <- sourceLint
  ok2 <- if os == "darwin" then weakLint else pure True
  unless (ok1 && ok2) exitFailure
  putStrLn "weakcheck: ok"

-- | No CPython data symbol may be referenced from the shim or the headers.
sourceLint :: IO Bool
sourceLint = do
  files <- (<>) <$> listAll "cbits" <*> listAll ("include" </> "h2py")
  results <- forM (filter (\f -> ".c" `isSuffixOf` f || ".h" `isSuffixOf` f) files) \f -> do
    ls <- lines <$> readFile f
    let bad = [(n, l) | (n, l) <- zip [1 :: Int ..] ls, any (`isInfixOf` l) dataSymbols, not ("//" `isPrefixOf` dropWhile (== ' ') l), not (" * " `isInfixOf` l), not ("/*" `isInfixOf` l)]
    forM_ bad \(n, l) -> putStrLn (f <> ":" <> show n <> ": CPython data symbol referenced: " <> l)
    pure (null bad)
  pure (and results)
  where
    dataSymbols = ["PyExc_", "Py_None", "Py_True", "Py_False", "Py_NotImplemented", "_Py_NoneStruct", "&PyLong_Type", "&PyBaseObject_Type", "&PyUnicode_Type", "&PyType_Type", "_Type;"]

listAll :: FilePath -> IO [FilePath]
listAll dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- map (dir </>) <$> listDirectory dir
      files <- filterM doesFileExist entries
      dirs <- filterM doesDirectoryExist entries
      rest <- concat <$> mapM listAll dirs
      pure (files <> rest)

-- | Every CPython reference of the built library is weak and listed in weakapi.h.
weakLint :: IO Bool
weakLint = do
  libs <- findLibs
  case libs of
    [] -> do
      putStrLn "weakcheck: no built libHSh2py dylib found; run cabal build h2py first"
      pure False
    (lib : _) -> do
      out <- readProcess "nm" ["-m", lib] ""
      let refs = [w | l <- lines out, "(undefined)" `isInfixOf` l, w <- take 1 [x | x <- words l, "_Py" `isPrefixOf` x || "__Py" `isPrefixOf` x]]
          strong = [l | l <- lines out, "(undefined) external _Py" `isInfixOf` l || "(undefined) external __Py" `isInfixOf` l]
      pragmas <- lines <$> readFile ("include" </> "h2py" </> "weakapi.h")
      let listed = mapMaybe (\l -> if "#pragma weak " `isPrefixOf` l then Just (drop (length "#pragma weak ") l) else Nothing) pragmas
          missing = nub (sort [drop 1 r | r <- refs, drop 1 r `notElem` listed])
      forM_ strong \l -> putStrLn ("weakcheck: strong CPython reference: " <> l)
      forM_ missing \s -> putStrLn ("weakcheck: weakapi.h lacks " <> s <> "; run scripts/gen-weakapi.sh")
      when (null strong && null missing) $ putStrLn ("weakcheck: " <> show (length refs) <> " weak references in " <> lib)
      pure (null strong && null missing)

-- | The built dylib, under this package's or the project's dist-newstyle.
findLibs :: IO [FilePath]
findLibs = do
  candidates <- concat <$> mapM listAll ["dist-newstyle", ".." </> "dist-newstyle"]
  pure [f | f <- candidates, "libHSh2py-" `isPrefixOf` lastComponent f, ".dylib" `isSuffixOf` f]
  where
    lastComponent = reverse . takeWhile (/= '/') . reverse
