module RunTests where

import Control.Monad
import Data.Char
import Data.List
import Data.Maybe
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.Process

------------------------------------------------------------------------

latexDir   = "latex"
succeedDir = "succeed"

main :: IO ()
main = do

  args <- getArgs

  case args of
    [agdaBin, "runTests"] -> runTests agdaBin
    ["clean"]             -> clean
    _                     -> do
      putStrLn "Wrong argument(s)."
      exitFailure

------------------------------------------------------------------------

runTests :: FilePath -> IO ()
runTests agdaBin = do

  dir   <- getCurrentDirectory
  files <- getDirectoryContents $ dir </> succeedDir

  let lagdas = sort $ filter (".lagda" `isSuffixOf`) files
  let texs   = sort $ filter (".tex"   `isSuffixOf`) files

  when (length lagdas /= length texs) $ do

    putStrLn "Not as many .lagda files as .tex files."
    exitFailure

  forM_ (zip lagdas texs) $ \(lagda, tex) -> do

    setCurrentDirectory $ dir </> succeedDir
    rawSystem agdaBin ["--latex", lagda]
    exit <- rawSystem "diff" [ "-u", latexDir </> tex, tex ]

    when (isFailure exit) $ do
      putStrLn ""
      putStrLn $ "Output of " ++ lagda ++ " is wrong!"
      exitFailure

    -- If a .compile exists in, then compile the produced .tex file.
    let compile = replaceExtension lagda "compile"
    exists <- doesFileExist compile

    when exists $ do
      content <- readFile compile
      setCurrentDirectory latexDir

      let allCompilers = ["pdflatex", "xelatex", "lualatex"]
      let compilers = fromMaybe allCompilers (readMaybe content)

      forM_ compilers $ \compiler -> do
        exit <- rawSystem compiler [ "-interaction=batchmode" , tex ]

        when (isFailure exit) $ do
          putStrLn ""
          putStrLn $ tex ++ " doesn't compile with " ++ compiler ++ "!"
          exitFailure

  putStrLn "All tests passed."

isFailure :: ExitCode -> Bool
isFailure (ExitFailure _) = True
isFailure _               = False

readMaybe :: Read a => String -> Maybe a
readMaybe s =
  case reads s of
    [(x, rest)] | all isSpace rest -> Just x
    _                              -> Nothing

------------------------------------------------------------------------

clean :: IO ()
clean = do

  dir <- getCurrentDirectory

  -- Remove latex directory, if it exists.
  exists <- doesDirectoryExist $ dir </> succeedDir </> latexDir
  when exists $
    removeDirectoryRecursive $ dir </> succeedDir </> latexDir

  -- Remove interface files.
  files <- getDirectoryContents $ dir </> succeedDir
  let agdais = filter (".agdai" `isSuffixOf`) files
  forM_ agdais $ \agdai ->
    removeFile $ succeedDir </> agdai
