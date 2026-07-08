use std::io::{Read, Write};
use std::sync::Mutex;
use std::thread;

use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use rustler::{
    Atom, Binary, Encoder, Env, NifResult, OwnedBinary, OwnedEnv, ResourceArc,
};

mod atoms {
    rustler::atoms! {
        ok,
        pty_data,
        pty_exit,
    }
}

// portable-pty's `Box<dyn MasterPty>` lacks a `Send` bound, but the unix
// implementation only wraps file descriptors; access is serialized by the
// surrounding Mutex.
struct SendMaster(Box<dyn MasterPty>);
unsafe impl Send for SendMaster {}

pub struct PtyResource {
    master: Mutex<SendMaster>,
    writer: Mutex<Option<Box<dyn Write + Send>>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
    child_pid: Option<u32>,
}

impl Drop for PtyResource {
    fn drop(&mut self) {
        if let Ok(mut killer) = self.killer.lock() {
            let _ = killer.kill();
        }
    }
}

#[rustler::resource_impl]
impl rustler::Resource for PtyResource {}

fn to_error(err: impl ToString) -> rustler::Error {
    rustler::Error::Term(Box::new(err.to_string()))
}

#[rustler::nif(schedule = "DirtyIo")]
fn open(
    env: Env,
    id: String,
    shell: String,
    // Named `argv` because rustler's nif macro reserves `args` internally.
    argv: Vec<String>,
    cwd: String,
    envs: Vec<(String, String)>,
    rows: u16,
    cols: u16,
) -> NifResult<ResourceArc<PtyResource>> {
    let owner = env.pid();

    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(to_error)?;

    let mut cmd = CommandBuilder::new(shell);
    cmd.args(argv);
    if !cwd.is_empty() {
        cmd.cwd(cwd);
    }
    for (key, value) in envs {
        cmd.env(key, value);
    }

    let mut child = pair.slave.spawn_command(cmd).map_err(to_error)?;
    drop(pair.slave);

    let child_pid = child.process_id();
    let killer = child.clone_killer();
    let mut reader = pair.master.try_clone_reader().map_err(to_error)?;
    let writer = pair.master.take_writer().map_err(to_error)?;

    thread::spawn(move || {
        let mut buf = [0u8; 8192];
        let mut msg_env = OwnedEnv::new();

        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let _ = msg_env.send_and_clear(&owner, |env| {
                        let mut bin = OwnedBinary::new(n).expect("binary allocation failed");
                        bin.as_mut_slice().copy_from_slice(&buf[..n]);
                        (atoms::pty_data(), &id, Binary::from_owned(bin, env)).encode(env)
                    });
                }
                // On Linux the read fails with EIO once the child exits.
                Err(_) => break,
            }
        }

        let status = child.wait().map(|s| s.exit_code()).unwrap_or(0);
        let _ = msg_env
            .send_and_clear(&owner, |env| (atoms::pty_exit(), &id, status).encode(env));
    });

    Ok(ResourceArc::new(PtyResource {
        master: Mutex::new(SendMaster(pair.master)),
        writer: Mutex::new(Some(writer)),
        killer: Mutex::new(killer),
        child_pid,
    }))
}

#[rustler::nif(schedule = "DirtyIo")]
fn write(resource: ResourceArc<PtyResource>, data: Binary) -> NifResult<Atom> {
    let mut guard = resource.writer.lock().unwrap();

    match guard.as_mut() {
        Some(writer) => {
            writer.write_all(data.as_slice()).map_err(to_error)?;
            writer.flush().map_err(to_error)?;
            Ok(atoms::ok())
        }
        None => Err(to_error("closed")),
    }
}

#[rustler::nif]
fn resize(resource: ResourceArc<PtyResource>, rows: u16, cols: u16) -> NifResult<Atom> {
    let guard = resource.master.lock().unwrap();

    guard
        .0
        .resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(to_error)?;

    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyIo")]
fn kill(resource: ResourceArc<PtyResource>) -> NifResult<Atom> {
    let _ = resource.killer.lock().unwrap().kill();
    Ok(atoms::ok())
}

#[rustler::nif]
fn child_pid(resource: ResourceArc<PtyResource>) -> Option<u32> {
    resource.child_pid
}

rustler::init!("Elixir.Dala.Pty");
