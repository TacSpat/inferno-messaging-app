pub use makepad_widgets;

use makepad_widgets::*;

app_main!(App);

script_mod! {
    use mod.prelude.widgets.*

    startup() do #(App::script_component(vm)){
        ui: Root{
            main_window := Window{
                window.title: "Inferno"
                window.inner_size: vec2(1280, 800)
                body +: {
                    SolidView{
                        width: Fill
                        height: Fill
                        flow: Right
                        draw_bg.color: #x2c2a29 // gray-700: chat column

                        SolidView{
                            width: 72 // server rail, gray-950
                            height: Fill
                            draw_bg.color: #x0a0a09
                        }
                        SolidView{
                            width: 240
                            height: Fill
                            draw_bg.color: #x1e1c1b
                        }
                        View{
                            width: Fill
                            height: Fill
                            align: Center
                            Label{
                                text: "Inferno"
                                draw_text.color: #xe1e0df
                                draw_text.text_style.font_size: 16
                            }
                        }
                        SolidView{
                            width: 240
                            height: Fill
                            draw_bg.color: #x1e1c1b
                        }
                    }
                }
            }
        }
    }
}

#[derive(Script, ScriptHook)]
pub struct App {
    #[live]
    ui: WidgetRef,
}

impl MatchEvent for App {}

impl AppMain for App {
    fn script_mod(vm: &mut ScriptVm) -> ScriptValue {
        crate::makepad_widgets::script_mod(vm);
        self::script_mod(vm)
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event) {
        self.match_event(cx, event);
        self.ui.handle_event(cx, event, &mut Scope::empty());
    }
}
