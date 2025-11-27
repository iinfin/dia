use anyhow::{Context, Result, bail};
use std::path::PathBuf;

const DIA_DATA_DIR: &str = "Library/Application Support/Dia/User Data";

pub struct Config {
    pub profile_path: PathBuf,
}

impl Config {
    pub fn new(profile: &str) -> Result<Self> {
        let home = std::env::var("HOME").context("HOME environment variable not set")?;
        let data_dir = PathBuf::from(&home).join(DIA_DATA_DIR);

        if !data_dir.exists() {
            bail!(
                "dia data directory not found at {}",
                data_dir.display()
            );
        }

        let profile_path = data_dir.join(profile);
        if !profile_path.exists() {
            let available = Self::list_profiles(&data_dir)?;
            bail!(
                "profile '{}' not found (available: {})",
                profile,
                available.join(", ")
            );
        }

        Ok(Self { profile_path })
    }

    pub fn history_path(&self) -> PathBuf {
        self.profile_path.join("History")
    }

    pub fn bookmarks_path(&self) -> PathBuf {
        self.profile_path.join("Bookmarks")
    }

    pub fn sessions_dir(&self) -> PathBuf {
        self.profile_path.join("Sessions")
    }

    fn list_profiles(data_dir: &PathBuf) -> Result<Vec<String>> {
        let mut profiles = Vec::new();
        for entry in std::fs::read_dir(data_dir)? {
            let entry = entry?;
            if entry.path().is_dir() {
                let name = entry.file_name().to_string_lossy().to_string();
                if !name.starts_with('.') {
                    profiles.push(name);
                }
            }
        }
        Ok(profiles)
    }
}
