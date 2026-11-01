[
  {true, nil, "\n"},
  {true, "plain", "plain\n"},
  {true, ["nested", ["value"]], "nestedvalue\n"},
  {true, [:orange, "orange"], "\e[38;5;214morange\e[0m\n"},
  {true, [:bright, :red, "red", :reset, :cyan, "cyan"],
   "\e[1m\e[31mred\e[0m\e[36mcyan\e[0m\n"},
  {true,
   [:faint, :green, :magenta, :yellow, :blue, :white, :default_color, "text"],
   "\e[2m\e[32m\e[35m\e[33m\e[34m\e[37m\e[39mtext\e[0m\n"},
  {false, nil, "\n"},
  {false, "plain", "plain\n"},
  {false, ["nested", ["value"]], "nestedvalue\n"},
  {false, [:orange, "orange"], "orange\n"},
  {false, [:bright, :red, "red", :reset, :cyan, "cyan"], "redcyan\n"},
  {false,
   [:faint, :green, :magenta, :yellow, :blue, :white, :default_color, "text"],
   "text\n"}
]
