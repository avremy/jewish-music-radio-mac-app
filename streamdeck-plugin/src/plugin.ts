import streamDeck from "@elgato/streamdeck";
import { JewishMusicAction } from "./actions/jewish-music";

streamDeck.actions.registerAction(new JewishMusicAction());
streamDeck.connect();
