use rustler::{Binary, Env, OwnedBinary};
use tiny_skia::{Pixmap, Transform};

fn render(svg: &[u8], width: u32, height: u32) -> Result<Vec<u8>, String> {
    if width == 0 || height == 0 || width > 4096 || height > 4096 {
        return Err("preview dimensions must be between 1 and 4096 pixels".to_string());
    }

    let options = usvg::Options::default();
    let tree = usvg::Tree::from_data(svg, &options).map_err(|error| error.to_string())?;
    let mut pixmap = Pixmap::new(width, height).ok_or("cannot allocate preview pixmap")?;
    let scale_x = width as f32 / tree.size().width();
    let scale_y = height as f32 / tree.size().height();

    resvg::render(
        &tree,
        Transform::from_scale(scale_x, scale_y),
        &mut pixmap.as_mut(),
    );

    pixmap.encode_png().map_err(|error| error.to_string())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn render_png<'a>(
    env: Env<'a>,
    svg: Binary<'a>,
    width: u32,
    height: u32,
) -> Result<Binary<'a>, String> {
    let png = render(svg.as_slice(), width, height)?;
    let mut output = OwnedBinary::new(png.len()).ok_or("cannot allocate PNG result")?;
    output.as_mut_slice().copy_from_slice(&png);
    Ok(Binary::from_owned(output, env))
}

rustler::init!("Elixir.Dala.ThemeRenderer");

#[cfg(test)]
mod tests {
    use super::render;

    const SVG: &[u8] = br##"<svg xmlns="http://www.w3.org/2000/svg" width="4" height="3"><rect width="4" height="3" fill="#123456"/></svg>"##;

    #[test]
    fn emits_a_deterministic_png() {
        let first = render(SVG, 4, 3).unwrap();
        let second = render(SVG, 4, 3).unwrap();
        assert_eq!(&first[..8], b"\x89PNG\r\n\x1a\n");
        assert_eq!(first, second);
    }
}
