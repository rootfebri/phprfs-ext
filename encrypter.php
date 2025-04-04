#!/usr/bin/env php
<?php

use JetBrains\PhpStorm\NoReturn;

if (!extension_loaded('phprfs')) {
  throw new RuntimeException('RFS encryption library not found');
}

class Exclusions {
  /** @var array $items List of excluded items */
  protected array $items = [];

  public function has($item): bool
  {
    return in_array(ltrim($item, '!'), $this->items, true);
  }

  public function dedup(): void
  {
    $this->items = array_unique($this->items);
  }

  public function add($item): void
  {
    $this->items[] = ltrim($item, '!');
  }
}

class Encrypter {
  protected string $scriptName = 'encrypter.php';
  protected array $argv = [];
  protected array $files = [];
  protected Exclusions $exclusions;
  private bool $silent = false;

  public function __construct($argv)
  {
    $this->argv = $argv;
    $this->scriptName = $this->argv[0] ?? basename(__FILE__);
    array_shift($this->argv);

    if (($c = $this->argv[0] ?? null) !== null) {
      match (true) {
        $c === '-h'
        || $c === '--help'
        || count($this->argv) <= 0
        || array_sum(array_map(static fn($c1) => (int)($c1 === '-h' || $c1 === '--help'), $this->argv)) > 0
        => $this->usage(),
        default => null,
      };
    }
    $this->exclusions = new Exclusions;
  }

  #[NoReturn] private function usage(): void
  {
    echo "Usage: php {$this->scriptName()} [FILES|FOLDERS] | [options]\n";
    echo "Options:\n";
    echo "  -s, --silent              Do not print info\n";
    echo "  -h, --help                Display this help message\n";
    echo "\n";
    echo "\n";
    echo "Example: php {$this->scriptName()} files.list path/to/file.php /absolute/path/to/file.php !path/to/file2.php !/absolute/path/should/not/encrypted \n";
    echo "\n";
    exit(0);
  }

  private function scriptName()
  {
    return $this->scriptName;
  }

  public function __destruct()
  {
    $this->start();
  }

  private function start(): void
  {
    foreach ($this->argv as $arg) {
      if (str_starts_with($arg, '!')) {
        $this->exclude($arg);
      } elseif ($this->isPhp($arg)) {
        $this->add($arg);
      } elseif (is_dir($arg)) {
        $this->scandir($arg);
      } elseif (pathinfo($arg, PATHINFO_EXTENSION) === 'list') {
        $this->yieldFromFile($arg);
      } else {
        $this->matchOptions($arg);
      }
    }
    $this->dedup();
    $this->run();
  }

  private function exclude(string $item): void
  {
    $this->exclusions->add($item);
  }

  private function add($file): void
  {
    $this->files[] = $file;
  }

  private function isPhp($file): bool
  {
    return pathinfo($file, PATHINFO_EXTENSION) === 'php';
  }

  private function scandir(string $dir): void
  {
    $entries = array_map('trim', scandir($dir));
    foreach ($entries as $entry) {
      if ($entry === '.' || $entry === '..') {
        continue;
      }

      $path = "$dir/$entry";
      if ($this->isExclusive($path)) {
        $this->info("Skipping file '$path' (excluded)\n");
        $this->exclude($path);
      } elseif ($this->isPhp($path)) {
        $this->info("Found valid PHP file: '$path' from: '$dir'\n");
        $this->add($path);
      } elseif (is_dir($path)) {
        $this->info("Scanning directory '$path'...\n");
        $this->scandir($path);
      } else {
        $this->info("'$path' is not a valid file or directory\n");
      }
    }
  }

  private function isExclusive($path): bool
  {
    return str_starts_with($path, '!');
  }

  private function info($msg): void
  {
    if (!$this->silent) {
      echo trim($msg) . PHP_EOL;
    }
  }

  private function yieldFromFile(string $input): void
  {
    $lines = array_values(array_filter(file($input, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES)));
    foreach ($lines as $entry) {
      if ($this->isExclusive($entry)) {

        $this->exclude($entry);

      } elseif (is_dir($entry)) {

        $this->scandir($entry);

      } elseif ($this->isPhp($entry)) {

        $this->add($entry);

      } else {

        $this->info("'$entry' is not a valid file or directory\n");

      }
    }
  }

  private function matchOptions($case): void
  {
    match ($case) {
      '-s' | '--silent' => $this->silent = true,
      '-h' | '--help' => $this->usage(),
      default => print("Unknown option: '$case'\n"),
    };
  }

  private function dedup(): void
  {
    $this->files = array_unique($this->files);
    $this->exclusions->dedup();
  }

  private function run(): void
  {
    $this->info("Encrypting files...\n");
    foreach ($this->files as $file) {
      $this->encrypt($file);
    }
    $this->info("Encryption completed\n");
  }

  private function encrypt(string $file): void
  {
    $this->info("Encrypting '$file'...\n");
    if (!is_file($file) || !file_exists($file)) {
      $this->info("File '$file' does not exist\n");
    } elseif ($this->exclusions->has($file)) {
      $this->info("Skipping file '$file' (excluded)\n");
    } elseif (!$this->isPhp($file)) {
      $this->info("Skipping file '$file' (not a PHP file)\n");
    } else {
      $encrypted = rfs_encrypt(file_get_contents($file));
      $content = "<?php rfs_eval('$encrypted');";
      file_put_contents($file, $content);
    }
  }
}

new Encrypter($argv);

